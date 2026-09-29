# frozen_string_literal: true

require "open3"
require "quaack/driver/burndown"
require "quaack/driver/llm"
require_relative "support/anthropic_credentials"
require_relative "support/fake_llm"

# The exact text of the errors both groups below expect.
module LLMClientMessages
  include AnthropicCredentials

  def no_credentials
    "llm_auth: no Anthropic credentials: set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN, or run `ant auth login`"
  end

  def unloadable_credentials = "llm_auth: the Anthropic credentials couldn't be loaded"

  def real_in_specs
    "a spec built an LLM client that would call the real API. " \
      "Pass a transport, such as FakeLLM, or set QUAACK_ALLOW_REAL_LLM=1 to mean it."
  end
end

RSpec.describe Quaack::Driver::LLM::Client do
  let(:burndown) { Quaack::Driver::Burndown.new }
  let(:fake) { FakeLLM.new }
  let(:client) { fake.client(burndown: burndown) }
  let(:messages) { [{ role: "user", content: "Propose indexes for this shape." }] }

  def ask(step = "5a-5", **)
    client.ask(step: step, messages: messages, max_tokens: 1000, **)
  end

  # The LLM::Error an ask raises. Fails the spec if it raises nothing.
  def ask_error(step = "5a-5", **)
    ask(step, **)
    raise "expected an LLM::Error for step #{step}, but the ask succeeded"
  rescue Quaack::Driver::LLM::Error => e
    e
  end

  # The error for rule, whose message is exactly message when one is given.
  def llm_error(rule, message = nil)
    raise_error(Quaack::Driver::LLM::Error) do |e|
      expect(e.rule).to eq(rule)
      expect(e.message).to eq(message) if message
    end
  end

  include LLMClientMessages

  def bad_json = "llm_bad_response: the reply wasn't valid JSON"
  def no_match = "llm_bad_response: the reply didn't match the schema"
  def unreadable = "llm_bad_response: the reply couldn't be read as a message"

  def step_error
    "step must be a step that calls an LLM, one of " \
      "#{Quaack::Protocol::Burndown::LLM_STEPS.join(", ")}"
  end

  def stopped_for(reason) = "llm_bad_response: the reply stopped for #{reason}"

  it "is loaded by quaack/driver" do
    code = 'require "quaack/driver"; print Quaack::Driver::LLM::Client.instance_method(:ask).name'
    out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", code)

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq("ask")
  end

  describe "#ask" do
    it "returns the reply's text" do
      fake.reply("5a-5", "CREATE INDEX ON orders (status)")

      expect(ask).to eq("CREATE INDEX ON orders (status)")
    end

    it "joins the reply's text blocks, in order" do
      fake.reply_blocks("5a-5", [{ type: "text", text: "CREATE INDEX " }, { type: "text", text: "ON t (a)" }])

      expect(ask).to eq("CREATE INDEX ON t (a)")
    end

    it "returns only the text blocks, leaving out any other kind" do
      fake.reply_blocks("5a-5", [{ type: "thinking", thinking: "SENTINEL-THOUGHT", signature: "sig" },
                                 { type: "text", text: "CREATE INDEX ON t (a)" }])

      expect(ask).to eq("CREATE INDEX ON t (a)")
    end

    it "sends the model, system prompt, messages, and max_tokens" do
      fake.reply("6a", "ok")
      client.ask(step: "6a", system: "You rewrite SQL.", messages: messages, max_tokens: 321)

      expect(fake.asks.map(&:body)).to eq([{ model: "claude-opus-5-5", max_tokens: 321, system: "You rewrite SQL.",
                                             messages: messages }])
    end

    it "leaves the system prompt out when there isn't one" do
      fake.reply("6a", "ok")
      ask("6a")

      expect(fake.asks.first.body.keys).to eq(%i[model max_tokens messages])
    end
  end

  describe "the burndown" do
    it "counts one LLM call for each ask, under its step" do
      fake.reply("5a-5", "a").reply("5a-5", "b").reply("10a", "c")
      ask("5a-5")
      ask("5a-5")
      ask("10a")

      expect(burndown.llm_calls).to eq("5a-5" => 2, "10a" => 1)
    end

    it "counts every attempt, since a retry is an API call too" do
      fake.error("6a", status: 529).error("6a", status: 429).reply("6a", "ok")

      expect(ask("6a")).to eq("ok")
      expect(burndown.llm_calls).to eq("6a" => 3)
      expect(fake.asks.size).to eq(3)
    end

    it "counts attempts that end in an error" do
      3.times { fake.error("step7", status: 529) }

      expect { ask("step7") }.to llm_error("llm_unavailable")
      expect(burndown.llm_calls).to eq("step7" => 3)
    end

    it "counts an attempt whose reply can't be used" do
      fake.reply("6a", "not json")

      expect { ask("6a", json: true) }.to llm_error("llm_bad_response", bad_json)
      expect(burndown.llm_calls).to eq("6a" => 1)
    end
  end

  describe "the step" do
    it "takes every step the protocol lists as one that calls an LLM" do
      Quaack::Protocol::Burndown::LLM_STEPS.each { fake.reply(it, it) }

      expect(Quaack::Protocol::Burndown::LLM_STEPS.map { ask(it) }).to eq(Quaack::Protocol::Burndown::LLM_STEPS)
    end

    it "refuses a step that doesn't call an LLM before making any call" do
      ["5a-3", "step8", "6A", :"6a", nil].each do |step|
        expect { ask(step) }.to raise_error(ArgumentError, step_error)
      end
      expect(fake.asks).to eq([])
      expect(burndown.llm_calls).to eq({})
    end

    it "holds a model to its own, lower non-streaming limit" do
      small = fake.client(burndown: burndown, model: "claude-opus-4-0")
      fake.reply("5a-5", "ok")

      expect(small.ask(step: "5a-5", messages: messages, max_tokens: 8192)).to eq("ok")
      expect { small.ask(step: "5a-5", messages: messages, max_tokens: 8193) }
        .to raise_error(ArgumentError, "max_tokens 8193 needs streaming, which this client doesn't do")
    end
  end

  describe "JSON replies" do
    let(:schema) do
      { type: "object", properties: { ddl: { type: "array", items: { type: "string" } } }, required: ["ddl"],
        additionalProperties: false }
    end

    it "asks for structured output with the schema and returns the parsed JSON" do
      fake.reply("5a-5", { "ddl" => ["CREATE INDEX ON t (a)"] })

      expect(ask(schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
      expect(fake.asks.first.body[:output_config]).to eq(format: { type: :json_schema, schema: schema })
    end

    it "ends the system prompt with the JSON-only line when there's a schema" do
      fake.reply("5a-5", { "ddl" => [] })
      ask(system: "You propose indexes.", schema: schema)

      expect(fake.asks.first.body[:system]).to eq("You propose indexes.\n\n#{described_class::JSON_ONLY}")
      expect(described_class::JSON_ONLY)
        .to eq("Reply with only the JSON object, with no code fences, commentary, or trailing text.")
    end

    it "leaves the system prompt as it is without a schema" do
      fake.reply("6a", [])
      ask("6a", system: "You rewrite SQL.", json: true)

      expect(fake.asks.first.body[:system]).to eq("You rewrite SQL.")
    end

    it "reads the JSON object out of a code fence with prose around it" do
      fake.reply("5a-5", "Here you go:\n\n```json\n{\"ddl\": [\"CREATE INDEX ON t (a)\"]}\n```\n\nHope that helps.")

      expect(ask(schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
    end

    it "reads a bare JSON object followed by trailing prose" do
      fake.reply("5a-5", "{\"ddl\": []}\nThese cover the filter.")

      expect(ask(schema: schema)).to eq("ddl" => [])
    end

    it "skips a stray example object in the prose and reads the one that matches the schema" do
      fake.reply("5a-5", "Using {\"a\": 1} as shown, here are the indexes:\n\n" \
                         "```json\n{\"ddl\": [\"CREATE INDEX ON t (a)\"]}\n```")

      expect(ask(schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
    end

    it "skips an earlier object whose required key has the wrong type" do
      fake.reply("5a-5", "For example {\"ddl\": \"one\"} is wrong. The answer: {\"ddl\": []}")

      expect(ask(schema: schema)).to eq("ddl" => [])
    end

    it "refuses a JSON reply that lacks a required key" do
      fake.reply("5a-5", { "indexes" => ["CREATE INDEX ON t (a)"] })

      expect { ask(schema: schema) }.to llm_error("llm_bad_response", no_match)
    end

    it "refuses a JSON reply whose required value has the wrong type" do
      fake.reply("5a-5", { "ddl" => { "sql" => "CREATE INDEX ON t (a)" } })

      expect { ask(schema: schema) }.to llm_error("llm_bad_response", no_match)
    end

    it "refuses prose whose only object doesn't match the schema" do
      fake.reply("5a-5", "Here is an example: {\"a\": 1}. That's all.")

      expect { ask(schema: schema) }.to llm_error("llm_bad_response", no_match)
    end

    it "checks object and string types of required values" do
      typed = { type: "object", required: %w[plan note],
                properties: { plan: { type: "object" }, note: { type: "string" } } }
      fake.reply("5a-5", "{\"plan\": [], \"note\": \"x\"} then {\"plan\": {}, \"note\": \"y\"}")
      fake.reply("5a-5", { "plan" => {}, "note" => 3 })

      expect(ask(schema: typed)).to eq("plan" => {}, "note" => "y")
      expect { ask(schema: typed) }.to llm_error("llm_bad_response", no_match)
    end

    it "parses the text as JSON when asked, without a schema" do
      fake.reply("6a", [{ "sql" => "SELECT 1" }])

      expect(ask("6a", json: true)).to eq([{ "sql" => "SELECT 1" }])
      expect(fake.asks.first.body).not_to have_key(:output_config)
    end

    it "fails with llm_bad_response on a reply that isn't JSON, without quoting it" do
      fake.reply("5a-5", "SENTINEL-REPLY {")

      e = ask_error(schema: schema)

      expect(e.rule).to eq("llm_bad_response")
      expect(e.message).to eq(bad_json)
      # The parser's own error quotes the reply, so it isn't kept as the cause.
      expect(e.cause).to be_nil
    end
  end

  describe "replies that can't be used" do
    it "fails with llm_bad_response on a reply cut short at max_tokens" do
      fake.reply("5a-5", "CREATE INDEX ON t (", stop_reason: "max_tokens")

      expect { ask }.to llm_error("llm_bad_response", stopped_for("max_tokens"))
    end

    it "fails with llm_bad_response on a refusal" do
      fake.reply("5a-5", "", stop_reason: "refusal")

      expect { ask }.to llm_error("llm_bad_response", stopped_for("refusal"))
    end

    it "fails with llm_bad_response on a reply with no text" do
      fake.reply_blocks("5a-5", [])

      expect { ask }.to llm_error("llm_bad_response", "llm_bad_response: the reply had no text")
    end

    # Only a reply that finished on its own, or at a stop sequence, is whole.
    %w[model_context_window_exceeded pause_turn tool_use brand_new_reason].each do |reason|
      it "fails with llm_bad_response on stop reason #{reason}" do
        fake.reply("5a-5", "CREATE INDEX ON t (a)", stop_reason: reason)

        expect { ask }.to llm_error("llm_bad_response", stopped_for(reason))
      end
    end

    it "takes a reply that ended at a stop sequence" do
      fake.reply("5a-5", "CREATE INDEX ON t (a)", stop_reason: "stop_sequence")

      expect(ask).to eq("CREATE INDEX ON t (a)")
    end

    it "fails with llm_bad_response on a reply the gem can't read as a message" do
      fake.raw("5a-5", JSON.generate(id: "m", type: "message", role: "assistant", model: "m", content: nil,
                                     stop_reason: "end_turn", stop_sequence: nil,
                                     usage: { input_tokens: 1, output_tokens: 1 }))

      expect { ask }.to llm_error("llm_bad_response", unreadable)
    end

    it "fails with llm_bad_response on a reply body that isn't a JSON object" do
      fake.raw("5a-5", JSON.generate(%w[SENTINEL-BODY])).raw("10a", "SENTINEL-BODY not json")

      [ask_error("5a-5"), ask_error("10a")].each do |e|
        expect(e.rule).to eq("llm_bad_response")
        expect(e.cause).to be_nil
        expect(e.message).to eq(unreadable)
      end
    end
  end

  describe "API errors" do
    it "fails with llm_rate_limited once the gem's retries run out on 429s" do
      3.times { fake.error("5a-5", status: 429) }

      expect { ask }.to llm_error("llm_rate_limited")
      expect(fake.asks.size).to eq(3)
    end

    # A dropped connection has no retry-after, so the gem backs off half a
    # second. One retry keeps the spec quick.
    it "fails with llm_unavailable once retries run out on dropped connections" do
      client = fake.client(burndown: burndown, max_retries: 1)
      2.times { fake.drop("5a-5") }

      expect { client.ask(step: "5a-5", messages: messages, max_tokens: 10) }.to llm_error("llm_unavailable")
      expect(burndown.llm_calls).to eq("5a-5" => 2)
    end

    it "fails with llm_unavailable on a server error that persists" do
      3.times { fake.error("5a-5", status: 500) }

      expect { ask }.to llm_error("llm_unavailable")
    end

    it "fails with llm_auth on a bad key or a forbidden request, without retrying" do
      fake.error("5a-5", status: 401).error("10a", status: 403)

      expect { ask("5a-5") }.to llm_error("llm_auth")
      expect { ask("10a") }.to llm_error("llm_auth")
      expect(burndown.llm_calls).to eq("5a-5" => 1, "10a" => 1)
    end

    # 408 is a timeout and 409 a lock, both passing, so the gem retries them
    # and what's left once it gives up is an API that isn't answering.
    it "fails with llm_unavailable once retries run out on 408s or 409s" do
      3.times { fake.error("5a-5", status: 408).error("10a", status: 409) }

      expect { ask("5a-5") }.to llm_error("llm_unavailable")
      expect { ask("10a") }.to llm_error("llm_unavailable")
      expect(burndown.llm_calls).to eq("5a-5" => 3, "10a" => 3)
    end

    it "fails with llm_bad_request on a request the API rejects, without retrying" do
      fake.error("5a-5", status: 400).error("10a", status: 404)

      expect { ask("5a-5") }.to llm_error("llm_bad_request")
      expect { ask("10a") }.to llm_error("llm_bad_request")
      expect(fake.asks.size).to eq(2)
    end

    it "retries as many times as max_retries says" do
      client = fake.client(burndown: burndown, max_retries: 0)
      fake.error("5a-5", status: 529)

      expect { client.ask(step: "5a-5", messages: messages, max_tokens: 10) }.to llm_error("llm_unavailable")
      expect(fake.asks.size).to eq(1)
    end

    it "keeps the API key out of its error messages" do
      client = Quaack::Driver::LLM::Client.new(api_key: "SENTINEL-KEY", burndown: burndown, transport: fake)
      [401, 400, 429, 429, 429].each { fake.error("5a-5", status: it) }

      seen = Array.new(3) do
        client.ask(step: "5a-5", messages: messages, max_tokens: 10)
      rescue Quaack::Driver::LLM::Error => e
        e.message
      end

      expect(seen).to match([/\Allm_auth: /, /\Allm_bad_request: /, /\Allm_rate_limited: /])
      expect(seen.join).not_to include("SENTINEL-KEY")
    end
  end

  describe "the credentials" do
    # FakeLLM never records headers, so this transport looks only at the
    # ones that carry credentials, and answers every attempt.
    let(:key_transport) do
      Class.new do
        attr_reader :seen

        def initialize = @seen = []

        def call(request, step:)
          @seen << request.headers.slice("x-api-key", "authorization")
          body = { id: "m", type: "message", role: "assistant", model: "m", stop_reason: "end_turn",
                   content: [{ type: "text", text: step }], stop_sequence: nil,
                   usage: { input_tokens: 1, output_tokens: 1 } }
          Anthropic::APIResponse.new(status: 200, headers: { "content-type" => "application/json" },
                                     body: JSON.generate(body), request: request)
        end
      end.new
    end

    def ask_with(client) = client.ask(step: "6a", messages: messages, max_tokens: 10)
    def key_env_settings = Quaack::Driver::LLM.settings({ "api_key_env" => "QUAACK_SPEC_KEY" }, env: {})

    it "sends the key it was given" do
      ask_with(described_class.new(api_key: "SENTINEL-GIVEN", burndown: burndown, transport: key_transport))

      expect(key_transport.seen).to eq([{ "x-api-key" => "SENTINEL-GIVEN" }])
    end

    it "sends ANTHROPIC_API_KEY when it isn't given one" do
      without_anthropic_credentials("ANTHROPIC_API_KEY" => "SENTINEL-FROM-ENV") do
        ask_with(described_class.new(burndown: burndown, transport: key_transport))
      end

      expect(key_transport.seen).to eq([{ "x-api-key" => "SENTINEL-FROM-ENV" }])
    end

    it "sends ANTHROPIC_AUTH_TOKEN as a bearer token when there's no API key" do
      without_anthropic_credentials("ANTHROPIC_AUTH_TOKEN" => "SENTINEL-TOKEN") do
        ask_with(described_class.new(burndown: burndown, transport: key_transport))
      end

      expect(key_transport.seen).to eq([{ "authorization" => "Bearer SENTINEL-TOKEN" }])
    end

    it "sends the token of an `ant auth login` profile when there's no key or token" do
      without_anthropic_credentials do |dir|
        write_profile(dir, "SENTINEL-PROFILE-TOKEN")
        ask_with(described_class.new(burndown: burndown, transport: key_transport))
      end

      expect(key_transport.seen).to eq([{ "authorization" => "Bearer SENTINEL-PROFILE-TOKEN" }])
    end

    it "sends the key from the variable api_key_env names, over ANTHROPIC_API_KEY" do
      without_anthropic_credentials("ANTHROPIC_API_KEY" => "SENTINEL-DEFAULT", "QUAACK_SPEC_KEY" => "SENTINEL-NAMED") do
        ask_with(described_class.new(settings: key_env_settings, burndown: burndown, transport: key_transport))
      end

      expect(key_transport.seen).to eq([{ "x-api-key" => "SENTINEL-NAMED" }])
    end

    it "fails with llm_auth, naming the variable, when api_key_env's variable is unset or empty" do
      [nil, ""].each do |value|
        without_anthropic_credentials("ANTHROPIC_API_KEY" => "SENTINEL-DEFAULT", "QUAACK_SPEC_KEY" => value) do
          expect { described_class.new(settings: key_env_settings, burndown: burndown, transport: key_transport) }
            .to raise_error(Quaack::Driver::LLM::Error, "llm_auth: QUAACK_SPEC_KEY isn't set")
        end
      end
      expect(key_transport.seen).to eq([])
    end

    it "fails with llm_auth before any attempt when it finds no credentials, or only empty ones" do
      [{}, { "ANTHROPIC_API_KEY" => "" }, { "ANTHROPIC_AUTH_TOKEN" => "" }].each do |env|
        without_anthropic_credentials(env) do
          expect { described_class.new(burndown: burndown, transport: key_transport) }
            .to raise_error(Quaack::Driver::LLM::Error, no_credentials)
        end
      end
      without_anthropic_credentials do
        expect { described_class.new(api_key: "", burndown: burndown, transport: key_transport) }
          .to raise_error(Quaack::Driver::LLM::Error, no_credentials)
      end
      expect(key_transport.seen).to eq([])
    end

    it "fails with llm_auth when the profile ANTHROPIC_PROFILE names can't be loaded" do
      without_anthropic_credentials("ANTHROPIC_PROFILE" => "missing") do
        expect { described_class.new(burndown: burndown, transport: key_transport) }
          .to raise_error(Quaack::Driver::LLM::Error, unloadable_credentials)
      end
    end

    it "fails with llm_auth, counting no attempt, when the profile's token can't be read at ask time" do
      without_anthropic_credentials do |dir|
        write_profile(dir, nil)
        client = described_class.new(burndown: burndown, transport: key_transport)

        expect { ask_with(client) }.to raise_error(Quaack::Driver::LLM::Error, unloadable_credentials)
      end
      expect(key_transport.seen).to eq([])
      expect(burndown.llm_calls).to eq({})
    end

    # With a profile, the gem retries a 401 as it does a 429, rereading the
    # token each time, so every attempt counts.
    it "fails with llm_auth when the API refuses a profile's token" do
      3.times { fake.error("5a-5", status: 401) }
      without_anthropic_credentials do |dir|
        write_profile(dir, "SENTINEL-PROFILE-TOKEN")
        client = described_class.new(burndown: burndown, transport: fake)

        expect { client.ask(step: "5a-5", messages: messages, max_tokens: 10) }.to llm_error("llm_auth")
      end
      expect(burndown.llm_calls).to eq("5a-5" => 3)
    end
  end

  describe "max_tokens" do
    # Past this, the gem says a request needs streaming, which the client
    # doesn't do yet.
    it "takes up to the gem's non-streaming limit" do
      fake.reply("5a-5", "ok")

      expect(client.ask(step: "5a-5", messages: messages, max_tokens: 21_333)).to eq("ok")
      expect(fake.asks.first.body[:max_tokens]).to eq(21_333)
    end

    it "refuses more than the gem's non-streaming limit before making any call" do
      expect { client.ask(step: "5a-5", messages: messages, max_tokens: 21_334) }
        .to raise_error(ArgumentError, "max_tokens 21334 needs streaming, which this client doesn't do")
      expect(fake.asks).to eq([])
      expect(burndown.llm_calls).to eq({})
    end
  end

  describe "the settings" do
    it "are LLM.settings unless they're given, so QUAACK_MODEL reaches every call" do
      fake.reply("5a-5", "ok")
      with_env("QUAACK_MODEL" => "claude-from-env") do
        described_class.new(api_key: "k", burndown: burndown, transport: fake)
                       .ask(step: "5a-5", messages: messages, max_tokens: 10)
      end

      expect(fake.asks.first.body[:model]).to eq("claude-from-env")
    end

    it "send the settings' model" do
      settings = Quaack::Driver::LLM.settings({ "model" => "claude-from-config" }, env: {})
      fake.reply("5a-5", "ok")
      described_class.new(settings:, api_key: "k", burndown: burndown, transport: fake)
                     .ask(step: "5a-5", messages: messages, max_tokens: 10)

      expect(fake.asks.first.body[:model]).to eq("claude-from-config")
    end

    it "send every attempt to the settings' base_url" do
      settings = Quaack::Driver::LLM.settings({ "base_url" => "https://llm.example.com/anthropic" }, env: {})
      fake.reply("6a", "ok")
      described_class.new(settings:, api_key: "k", burndown: burndown, transport: fake)
                     .ask(step: "6a", messages: messages, max_tokens: 10)

      expect(fake.asks.map(&:url)).to eq(["https://llm.example.com/anthropic/v1/messages"])
    end

    it "take a model given over the settings'" do
      settings = Quaack::Driver::LLM.settings({ "model" => "claude-from-config" }, env: {})
      fake.reply("5a-5", "ok")
      fake.client(burndown: burndown, model: "claude-other-1", settings:)
          .ask(step: "5a-5", messages: messages, max_tokens: 10)

      expect(fake.asks.first.body[:model]).to eq("claude-other-1")
    end
  end
end

RSpec.describe Quaack::Driver::LLM do
  include LLMClientMessages

  describe "a client with no transport, which would call the real API" do
    let(:burndown) { Quaack::Driver::Burndown.new }

    it "can't be built while specs run" do
      expect { described_class::Client.new(api_key: "k", burndown: burndown) }
        .to raise_error(described_class::RealClientInSpecs, real_in_specs)
    end

    it "can't be built in a process that loaded RSpec, even without the helpers' marker" do
      with_env("QUAACK_SPECS" => nil) do
        expect { described_class::Client.new(api_key: "k", burndown: burndown) }
          .to raise_error(described_class::RealClientInSpecs, real_in_specs)
      end
    end

    it "can be built in specs with the explicit opt-in" do
      with_env("QUAACK_ALLOW_REAL_LLM" => "1") do
        expect(described_class::Client.new(api_key: "k", burndown: burndown)).to be_a(described_class::Client)
      end
    end

    it "takes only 1 as the opt-in, not any other value" do
      with_env("QUAACK_ALLOW_REAL_LLM" => "yes") do
        expect { described_class::Client.new(api_key: "k", burndown: burndown) }
          .to raise_error(described_class::RealClientInSpecs, real_in_specs)
      end
    end

    it "fails with llm_auth when it finds no credentials" do
      without_anthropic_credentials("QUAACK_ALLOW_REAL_LLM" => "1") do
        expect { described_class::Client.new(burndown: burndown) }
          .to raise_error(described_class::Error, no_credentials)
      end
    end

    # Outside RSpec, with the marker the spec helpers set removed, nothing
    # stops it. It's built, never asked, so this makes no API call.
    it "can be built outside specs" do
      code = 'require "quaack/driver"; ' \
             'c = Quaack::Driver::LLM::Client.new(api_key: "k", burndown: Quaack::Driver::Burndown.new); print c.class'
      out, err, status = Open3.capture3({ "QUAACK_SPECS" => nil, "QUAACK_ALLOW_REAL_LLM" => nil },
                                        RbConfig.ruby, "-I", File.join(GEM_ROOT, "lib"), "-e", code)

      expect(status).to be_success, "stderr was #{err}"
      expect(out).to eq("Quaack::Driver::LLM::Client")
    end

    it "can be built outside specs when QUAACK_SPECS is set to something other than 1" do
      code = 'require "quaack/driver"; ' \
             'c = Quaack::Driver::LLM::Client.new(api_key: "k", burndown: Quaack::Driver::Burndown.new); print c.class'
      out, err, status = Open3.capture3({ "QUAACK_SPECS" => "0", "QUAACK_ALLOW_REAL_LLM" => nil },
                                        RbConfig.ruby, "-I", File.join(GEM_ROOT, "lib"), "-e", code)

      expect(status).to be_success, "stderr was #{err}"
      expect(out).to eq("Quaack::Driver::LLM::Client")
    end

    it "can't be built in a child process a spec starts, which inherits the helpers' marker" do
      code = 'require "quaack/driver"; ' \
             'Quaack::Driver::LLM::Client.new(api_key: "k", burndown: Quaack::Driver::Burndown.new)'
      _, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", code)

      expect(status).not_to be_success
      expect(err).to include("RealClientInSpecs")
    end
  end
end
