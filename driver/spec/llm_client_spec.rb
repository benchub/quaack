# frozen_string_literal: true

require "open3"
require "quaack/driver/burndown"
require "quaack/driver/llm"
require_relative "support/anthropic_credentials"
require_relative "support/fake_llm"
require_relative "support/anthropic_error_examples"
require_relative "support/llm_client_examples"

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

# The Anthropic adapter behind the client. The behavior every adapter
# shares is in support/llm_client_examples.rb.
RSpec.describe Quaack::Driver::LLM::Client do
  it_behaves_like "an LLM client" do
    let(:fake) { FakeLLM.new }
  end

  it_behaves_like "an Anthropic API's error detail" do
    let(:fake) { FakeLLM.new }
  end

  let(:burndown) { Quaack::Driver::Burndown.new }
  let(:fake) { FakeLLM.new }
  let(:client) { fake.client(burndown: burndown) }
  let(:messages) { [{ role: "user", content: "Propose indexes for this shape." }] }

  def ask(step = "llm-index-ideas", **)
    client.ask(step: step, messages: messages, max_tokens: 1000, **)
  end

  # The LLM::Error an ask raises. Fails the spec if it raises nothing.
  def ask_error(step = "llm-index-ideas", **)
    ask(step, **)
    raise "expected an LLM::Error for step #{step}, but the ask succeeded"
  rescue Quaack::Driver::LLM::Error => e
    e
  end

  # The error for rule, whose message is exactly message when one is given.
  def llm_error(rule, message = nil)
    raise_error(Quaack::Driver::LLM::Error) do |e|
      expect(e.rule).to eq(rule)
      expect(sans_sizes(e.message)).to eq(message) if message
    end
  end

  include LLMClientMessages

  def bad_json = "llm_bad_response: the reply wasn't valid JSON"
  def no_match = "llm_bad_response: the reply didn't match the schema"
  def unreadable = "llm_bad_response: the reply couldn't be read as a message"

  def stopped_for(reason) = "llm_bad_response: the reply stopped for #{reason}"

  it "is loaded by quaack/driver" do
    code = 'require "quaack/driver"; print Quaack::Driver::LLM::Client.instance_method(:ask).name'
    out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", code)

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq("ask")
  end

  describe "#ask" do
    it "joins the reply's text blocks, in order" do
      fake.reply_blocks("llm-index-ideas",
                        [{ type: "text", text: "CREATE INDEX " }, { type: "text", text: "ON t (a)" }])

      expect(ask).to eq("CREATE INDEX ON t (a)")
    end

    it "returns only the text blocks, leaving out any other kind" do
      fake.reply_blocks("llm-index-ideas", [{ type: "thinking", thinking: "SENTINEL-THOUGHT", signature: "sig" },
                                            { type: "text", text: "CREATE INDEX ON t (a)" }])

      expect(ask).to eq("CREATE INDEX ON t (a)")
    end

    it "sends the model, system prompt, messages, and max_tokens" do
      fake.reply("llm-rewrites", "ok")
      client.ask(step: "llm-rewrites", system: "You rewrite SQL.", messages: messages, max_tokens: 321)

      expect(fake.asks.map(&:body)).to eq([{ model: "claude-opus-5-5", max_tokens: 321, system: "You rewrite SQL.",
                                             messages: messages }])
    end

    it "leaves the system prompt out when there isn't one" do
      fake.reply("llm-rewrites", "ok")
      ask("llm-rewrites")

      expect(fake.asks.first.body.keys).to eq(%i[model max_tokens messages])
    end
  end

  describe "the step" do
    it "holds a model to its own, lower non-streaming limit" do
      small = fake.client(burndown: burndown, model: "claude-opus-4-0")
      fake.reply("llm-index-ideas", "ok")

      expect(small.ask(step: "llm-index-ideas", messages: messages, max_tokens: 8192)).to eq("ok")
      expect { small.ask(step: "llm-index-ideas", messages: messages, max_tokens: 8193) }
        .to raise_error(ArgumentError, "max_tokens 8193 needs streaming, which this client doesn't do")
    end
  end

  describe "JSON replies" do
    let(:schema) do
      { type: "object", properties: { ddl: { type: "array", items: { type: "string" } } }, required: ["ddl"],
        additionalProperties: false }
    end

    it "asks for structured output with the schema and returns the parsed JSON" do
      fake.reply("llm-index-ideas", { "ddl" => ["CREATE INDEX ON t (a)"] })

      expect(ask(schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
      expect(fake.asks.first.body[:output_config]).to eq(format: { type: :json_schema, schema: schema })
    end

    it "ends the system prompt with the JSON-only line when there's a schema" do
      fake.reply("llm-index-ideas", { "ddl" => [] })
      ask(system: "You propose indexes.", schema: schema)

      expect(fake.asks.first.body[:system]).to eq("You propose indexes.\n\n#{described_class::JSON_ONLY}")
      expect(described_class::JSON_ONLY)
        .to eq("Reply with only the JSON object, with no code fences, commentary, or trailing text.")
    end

    it "leaves the system prompt as it is without a schema" do
      fake.reply("llm-rewrites", [])
      ask("llm-rewrites", system: "You rewrite SQL.", json: true)

      expect(fake.asks.first.body[:system]).to eq("You rewrite SQL.")
    end

    # Anthropic holds the reply to the schema, so one that doesn't match
    # isn't asked for again.
    it "refuses a JSON reply that lacks a required key, without asking again" do
      fake.reply("llm-index-ideas", { "indexes" => ["CREATE INDEX ON t (a)"] })

      expect { ask(schema: schema) }.to llm_error("llm_bad_response", no_match)
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 1)
    end

    it "refuses a JSON reply whose required value has the wrong type" do
      fake.reply("llm-index-ideas", { "ddl" => { "sql" => "CREATE INDEX ON t (a)" } })

      expect { ask(schema: schema) }.to llm_error("llm_bad_response", no_match)
    end

    it "refuses prose whose only object doesn't match the schema" do
      fake.reply("llm-index-ideas", "Here is an example: {\"a\": 1}. That's all.")

      expect { ask(schema: schema) }.to llm_error("llm_bad_response", no_match)
    end

    it "checks object and string types of required values" do
      typed = { type: "object", required: %w[plan note],
                properties: { plan: { type: "object" }, note: { type: "string" } } }
      fake.reply("llm-index-ideas", "{\"plan\": [], \"note\": \"x\"} then {\"plan\": {}, \"note\": \"y\"}")
      fake.reply("llm-index-ideas", { "plan" => {}, "note" => 3 })

      expect(ask(schema: typed)).to eq("plan" => {}, "note" => "y")
      expect { ask(schema: typed) }.to llm_error("llm_bad_response", no_match)
    end

    it "parses the text as JSON when asked, without a schema" do
      fake.reply("llm-rewrites", [{ "sql" => "SELECT 1" }])

      expect(ask("llm-rewrites", json: true)).to eq([{ "sql" => "SELECT 1" }])
      expect(fake.asks.first.body).not_to have_key(:output_config)
    end

    it "fails with llm_bad_response on a reply that isn't JSON, without quoting it" do
      fake.reply("llm-index-ideas", "SENTINEL-REPLY {")

      e = ask_error(schema: schema)

      expect(e.rule).to eq("llm_bad_response")
      expect(sans_sizes(e.message)).to eq(bad_json)
      # The parser's own error quotes the reply, so it isn't kept as the cause.
      expect(e.cause).to be_nil
    end
  end

  describe "replies that can't be used" do
    it "fails with llm_bad_response on a reply cut short at max_tokens" do
      fake.reply("llm-index-ideas", "CREATE INDEX ON t (", stop_reason: "max_tokens")

      expect { ask }.to llm_error("llm_bad_response", stopped_for("max_tokens"))
    end

    it "fails with llm_bad_response on a refusal" do
      fake.reply("llm-index-ideas", "", stop_reason: "refusal")

      expect { ask }.to llm_error("llm_bad_response", stopped_for("refusal"))
    end

    it "fails with llm_bad_response on a reply with no text" do
      fake.reply_blocks("llm-index-ideas", [])

      expect { ask }.to llm_error("llm_bad_response", "llm_bad_response: the reply had no text")
    end

    # Only a reply that finished on its own, or at a stop sequence, is whole.
    %w[model_context_window_exceeded pause_turn tool_use brand_new_reason].each do |reason|
      it "fails with llm_bad_response on stop reason #{reason}" do
        fake.reply("llm-index-ideas", "CREATE INDEX ON t (a)", stop_reason: reason)

        expect { ask }.to llm_error("llm_bad_response", stopped_for(reason))
      end
    end

    it "takes a reply that ended at a stop sequence" do
      fake.reply("llm-index-ideas", "CREATE INDEX ON t (a)", stop_reason: "stop_sequence")

      expect(ask).to eq("CREATE INDEX ON t (a)")
    end

    it "fails with llm_bad_response on a reply the gem can't read as a message" do
      fake.raw("llm-index-ideas", JSON.generate(id: "m", type: "message", role: "assistant", model: "m", content: nil,
                                                stop_reason: "end_turn", stop_sequence: nil,
                                                usage: { input_tokens: 1, output_tokens: 1 }))

      expect { ask }.to llm_error("llm_bad_response", unreadable)
    end

    it "fails with llm_bad_response on a reply body that isn't a JSON object" do
      fake.raw("llm-index-ideas", JSON.generate(%w[SENTINEL-BODY])).raw("llm-counterexamples", "SENTINEL-BODY not json")

      [ask_error("llm-index-ideas"), ask_error("llm-counterexamples")].each do |e|
        expect(e.rule).to eq("llm_bad_response")
        expect(e.cause).to be_nil
        expect(sans_sizes(e.message)).to eq(unreadable)
      end
    end
  end

  describe "the credentials" do
    # Task 20261007-54: a gateway's body can echo the bearer token too.
    it "scrubs ANTHROPIC_AUTH_TOKEN from an error detail" do
      fake.error_body("llm-index-ideas", status: 400, body: { error: { message: "bad token SENTINEL-AUTH-TOKEN" } })
      e = without_anthropic_credentials("ANTHROPIC_AUTH_TOKEN" => "SENTINEL-AUTH-TOKEN") do
        described_class.new(burndown: burndown, transport: fake).ask(step: "llm-index-ideas", messages:,
                                                                     max_tokens: 10)
      rescue Quaack::Driver::LLM::Error => e
        e
      end

      expect(sans_sizes(e.message)).to eq("llm_bad_request: the API answered 400: bad token [key]")
      expect(error_text(e)).not_to include("SENTINEL")
    end

    # Task 20261007-57: an `ant auth login` profile's token goes out as a
    # bearer token too, and a 401 makes the gem reread it, so every token
    # an attempt sent is scrubbed.
    it "scrubs every token an `ant auth login` profile sent, after a 401 rereads it" do
      echo = { error: { message: "not SENTINEL-PROFILE-OLD or SENTINEL-PROFILE-NEW" } }
      fake.error_body("llm-index-ideas", status: 401, body: { error: { message: "expired" } })
          .error_body("llm-index-ideas", status: 400, body: echo)
      sent = []
      e = without_anthropic_credentials do |dir|
        write_profile(dir, "SENTINEL-PROFILE-OLD")
        # The token rotates once the first attempt has gone out.
        rotating = lambda do |request, step:|
          sent << request.headers["authorization"]
          fake.call(request, step:).tap { write_profile(dir, "SENTINEL-PROFILE-NEW") }
        end
        described_class.new(burndown: burndown, transport: rotating, max_retries: 1)
                       .ask(step: "llm-index-ideas", messages:, max_tokens: 10)
      rescue Quaack::Driver::LLM::Error => e
        e
      end

      expect(sent).to eq(["Bearer SENTINEL-PROFILE-OLD", "Bearer SENTINEL-PROFILE-NEW"])
      expect(sans_sizes(e.message)).to eq("llm_bad_request: the API answered 400: not [key] or [key]")
      expect(error_text(e)).not_to include("SENTINEL")
    end

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

    def ask_with(client) = client.ask(step: "llm-rewrites", messages: messages, max_tokens: 10)
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

    it "sends the key it was given over the variable api_key_env names, even when that variable is unset" do
      ["SENTINEL-NAMED", nil].each do |named|
        without_anthropic_credentials("QUAACK_SPEC_KEY" => named) do
          ask_with(described_class.new(api_key: "SENTINEL-GIVEN", settings: key_env_settings, burndown: burndown,
                                       transport: key_transport))
        end
      end

      expect(key_transport.seen).to eq([{ "x-api-key" => "SENTINEL-GIVEN" }] * 2)
    end

    it "fails with llm_auth, naming the variable, when api_key_env's variable is unset" do
      without_anthropic_credentials("ANTHROPIC_API_KEY" => "SENTINEL-DEFAULT", "QUAACK_SPEC_KEY" => nil) do
        expect { described_class.new(settings: key_env_settings, burndown: burndown, transport: key_transport) }
          .to raise_error(Quaack::Driver::LLM::Error, "llm_auth: QUAACK_SPEC_KEY isn't set")
      end
      expect(key_transport.seen).to eq([])
    end

    it "fails with llm_auth, naming the variable, when api_key_env's variable is set but empty" do
      without_anthropic_credentials("ANTHROPIC_API_KEY" => "SENTINEL-DEFAULT", "QUAACK_SPEC_KEY" => "") do
        expect { described_class.new(settings: key_env_settings, burndown: burndown, transport: key_transport) }
          .to raise_error(Quaack::Driver::LLM::Error, "llm_auth: QUAACK_SPEC_KEY is set but empty")
      end
      expect(key_transport.seen).to eq([])
    end

    it "fails with llm_auth before any attempt when it finds no credentials, or is given an empty key" do
      without_anthropic_credentials do
        expect { described_class.new(burndown: burndown, transport: key_transport) }
          .to raise_error(Quaack::Driver::LLM::Error, no_credentials)
      end
      without_anthropic_credentials do
        expect { described_class.new(api_key: "", burndown: burndown, transport: key_transport) }
          .to raise_error(Quaack::Driver::LLM::Error, no_credentials)
      end
      expect(key_transport.seen).to eq([])
    end

    # The gem takes a set variable, even an empty one, as the credential,
    # and then looks no further: not at ANTHROPIC_AUTH_TOKEN after an empty
    # ANTHROPIC_API_KEY, and not at a profile after either.
    it "fails with llm_auth before any attempt when the variable the gem would use is set but empty" do
      [{ "ANTHROPIC_API_KEY" => "" }, { "ANTHROPIC_API_KEY" => "", "ANTHROPIC_AUTH_TOKEN" => "SENTINEL-TOKEN" },
       { "ANTHROPIC_AUTH_TOKEN" => "" }].each do |env|
        without_anthropic_credentials(env) do |dir|
          write_profile(dir, "SENTINEL-PROFILE-TOKEN")
          empty = env.key("")
          expect { described_class.new(burndown: burndown, transport: key_transport) }
            .to raise_error(Quaack::Driver::LLM::Error, "llm_auth: #{empty} is set but empty")
        end
      end
      expect(key_transport.seen).to eq([])
    end

    it "sends a key that doesn't come from an empty variable, whatever else is empty" do
      without_anthropic_credentials("ANTHROPIC_API_KEY" => "SENTINEL-FROM-ENV", "ANTHROPIC_AUTH_TOKEN" => "") do
        ask_with(described_class.new(burndown: burndown, transport: key_transport))
      end
      without_anthropic_credentials("ANTHROPIC_API_KEY" => "", "QUAACK_SPEC_KEY" => "SENTINEL-NAMED") do
        ask_with(described_class.new(settings: key_env_settings, burndown: burndown, transport: key_transport))
      end
      without_anthropic_credentials("ANTHROPIC_API_KEY" => "") do
        ask_with(described_class.new(api_key: "SENTINEL-GIVEN", burndown: burndown, transport: key_transport))
      end

      expect(key_transport.seen).to eq([{ "x-api-key" => "SENTINEL-FROM-ENV" }, { "x-api-key" => "SENTINEL-NAMED" },
                                        { "x-api-key" => "SENTINEL-GIVEN" }])
    end

    # The gem warns, once a process, when a key is used while
    # ANTHROPIC_API_KEY is set and a profile could be found. It says
    # ANTHROPIC_API_KEY took precedence, which is wrong when the key is one
    # QUAACK passed on purpose, from api_key_env's variable or given.
    describe "the gem's warning that ANTHROPIC_API_KEY shadows a profile" do
      let(:shadow_warning) { /ANTHROPIC_API_KEY is set and takes precedence/ }

      def build(**)
        Anthropic.instance_variable_set(:@warned_env_shadow, false)
        described_class.new(burndown: burndown, transport: key_transport, **)
      end

      it "isn't printed for a key QUAACK chose" do
        env = { "ANTHROPIC_API_KEY" => "SENTINEL-DEFAULT", "QUAACK_SPEC_KEY" => "SENTINEL-NAMED" }
        without_anthropic_credentials(env) do |dir|
          write_profile(dir, "SENTINEL-PROFILE-TOKEN")
          expect { build(settings: key_env_settings) }.not_to output.to_stderr
          expect { build(api_key: "SENTINEL-GIVEN") }.not_to output.to_stderr
        end
      end

      it "is still printed when the gem found ANTHROPIC_API_KEY itself" do
        without_anthropic_credentials("ANTHROPIC_API_KEY" => "SENTINEL-DEFAULT") do |dir|
          write_profile(dir, "SENTINEL-PROFILE-TOKEN")
          expect { build }.to output(shadow_warning).to_stderr
        end
      end

      # The gem passes keywords today. A later one might pass them
      # positionally, and skipping the warning mustn't then break the client.
      it "is skipped however the gem passes its arguments" do
        client = Quaack::Driver::LLM::AnthropicAdapter::GivenKeyClient.allocate
        without_anthropic_credentials("ANTHROPIC_API_KEY" => "SENTINEL-DEFAULT") do |dir|
          write_profile(dir, "SENTINEL-PROFILE-TOKEN")
          Anthropic.instance_variable_set(:@warned_env_shadow, false)
          expect { client.send(:warn_env_shadow, "SENTINEL-GIVEN", nil) }.not_to output.to_stderr
          expect { client.send(:warn_env_shadow, "SENTINEL-GIVEN", nil, api_key: "SENTINEL-GIVEN") }
            .not_to output.to_stderr
          expect(client.send(:warn_env_shadow, "SENTINEL-GIVEN", nil, api_key: "SENTINEL-GIVEN")).to be_nil
        end
      end
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

        expect { ask_with(client) }.to(raise_error(Quaack::Driver::LLM::Error) do |e|
          expect(sans_sizes(e.message)).to eq(unloadable_credentials)
        end)
      end
      expect(key_transport.seen).to eq([])
      expect(burndown.llm_calls).to eq({})
    end

    # With a profile, the gem retries a 401 as it does a 429, rereading the
    # token each time, so every attempt counts.
    it "fails with llm_auth when the API refuses a profile's token" do
      3.times { fake.error("llm-index-ideas", status: 401) }
      without_anthropic_credentials do |dir|
        write_profile(dir, "SENTINEL-PROFILE-TOKEN")
        client = described_class.new(burndown: burndown, transport: fake)

        expect { client.ask(step: "llm-index-ideas", messages: messages, max_tokens: 10) }.to llm_error("llm_auth")
      end
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 3)
    end
  end

  describe "max_tokens" do
    # Past this, the gem says a request needs streaming, which the client
    # doesn't do yet.
    it "takes up to the gem's non-streaming limit" do
      fake.reply("llm-index-ideas", "ok")

      expect(client.ask(step: "llm-index-ideas", messages: messages, max_tokens: 21_333)).to eq("ok")
      expect(fake.asks.first.body[:max_tokens]).to eq(21_333)
    end

    it "refuses more than the gem's non-streaming limit before making any call" do
      expect { client.ask(step: "llm-index-ideas", messages: messages, max_tokens: 21_334) }
        .to raise_error(ArgumentError, "max_tokens 21334 needs streaming, which this client doesn't do")
      expect(fake.asks).to eq([])
      expect(burndown.llm_calls).to eq({})
    end
  end

  describe "an ask the router makes for a provider" do
    let(:notes) { [] }

    before do
      seen = notes
      client.progress = Object.new.tap { |p| p.define_singleton_method(:note) { seen << it } }
    end

    it "counts every attempt under the provider too, retries included" do
      fake.error("llm-rewrites", status: 529).error("llm-rewrites", status: 429).reply("llm-rewrites", "ok")
      expect(ask("llm-rewrites", provider: "groq")).to eq("ok")

      expect(burndown.llm_calls).to eq("llm-rewrites" => 3)
      expect(burndown.llm_calls_by_provider).to eq("groq" => { "llm-rewrites" => 3 })
    end

    it "names the provider after the step in each progress line, when told to show it" do
      fake.error("llm-rewrites", status: 529).reply("llm-rewrites", "ok")
      ask("llm-rewrites", provider: "groq", shown: "groq")

      expect(notes).to eq(["Asking the LLM (llm-rewrites, groq)", "Asking the LLM, attempt 2 (llm-rewrites, groq)"])
    end

    it "shows no provider when not told to, though it counts under it" do
      fake.reply("llm-rewrites", "ok")
      ask("llm-rewrites", provider: "anthropic")

      expect(notes).to eq(["Asking the LLM (llm-rewrites)"])
      expect(burndown.llm_calls_by_provider).to eq("anthropic" => { "llm-rewrites" => 1 })
    end
  end

  describe "the settings" do
    it "are LLM.settings unless they're given, so QUAACK_MODEL reaches every call" do
      fake.reply("llm-index-ideas", "ok")
      with_env("QUAACK_MODEL" => "claude-from-env") do
        described_class.new(api_key: "k", burndown: burndown, transport: fake)
                       .ask(step: "llm-index-ideas", messages: messages, max_tokens: 10)
      end

      expect(fake.asks.first.body[:model]).to eq("claude-from-env")
    end

    it "send the settings' model" do
      settings = Quaack::Driver::LLM.settings({ "model" => "claude-from-config" }, env: {})
      fake.reply("llm-index-ideas", "ok")
      described_class.new(settings:, api_key: "k", burndown: burndown, transport: fake)
                     .ask(step: "llm-index-ideas", messages: messages, max_tokens: 10)

      expect(fake.asks.first.body[:model]).to eq("claude-from-config")
    end

    it "send every attempt to the settings' base_url" do
      settings = Quaack::Driver::LLM.settings({ "base_url" => "https://llm.example.com/anthropic" }, env: {})
      fake.reply("llm-rewrites", "ok")
      described_class.new(settings:, api_key: "k", burndown: burndown, transport: fake)
                     .ask(step: "llm-rewrites", messages: messages, max_tokens: 10)

      expect(fake.asks.map(&:url)).to eq(["https://llm.example.com/anthropic/v1/messages"])
    end

    # The block's host is meant for the block's provider, so the Anthropic
    # credentials must never go there.
    it "never send to the block's base_url when QUAACK_LLM_PROVIDER switches to anthropic" do
      settings = Quaack::Driver::LLM.settings({ "provider" => "bedrock", "model" => "m",
                                                "base_url" => "https://sentinel.example" },
                                              env: { "QUAACK_LLM_PROVIDER" => "anthropic" })
      fake.reply("llm-rewrites", "ok")
      with_env("ANTHROPIC_BASE_URL" => nil) do
        described_class.new(settings:, api_key: "k", burndown: burndown, transport: fake)
                       .ask(step: "llm-rewrites", messages: messages, max_tokens: 10)
      end

      expect(fake.asks.map(&:url)).to eq(["https://api.anthropic.com/v1/messages"])
      expect(fake.asks.map(&:url).join).not_to include("sentinel")
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

RSpec.describe Quaack::Driver::LLM::Client, "the size report on a failed ask" do
  let(:fake) { FakeLLM.new }
  let(:client) { fake.client(burndown: Quaack::Driver::Burndown.new) }
  let(:payload) do
    { "schema_subset" => "SENTINEL-SCHEMA" * 10, "query" => "SENTINEL-QUERY", "stats" => { "n" => "SENTINEL-N" } }
  end
  let(:payload_text) { "Here it is.\n\n```json\n#{JSON.pretty_generate(payload)}\n```\n" }

  def size_error(content)
    client.ask(step: "llm-index-ideas", system: "SENTINEL-SYSTEM", max_tokens: 4000,
               messages: [{ role: "user", content: content }, { role: "assistant", content: "SENTINEL-A" }])
    raise "expected an LLM::Error, but the ask succeeded"
  rescue Quaack::Driver::LLM::Error => e
    e
  end

  it "gives the step, max_tokens, system and message sizes, and the payload's keys largest first" do
    fake.error("llm-index-ideas", status: 400)
    e = size_error(payload_text)
    keys = payload.map { |k, v| [k, JSON.generate(v).length] }.sort_by { |_, n| -n }.map { |k, n| "#{k} #{n}" }

    expect(e.rule).to eq("llm_bad_request")
    expect(e.message).to end_with(
      " [step llm-index-ideas, max_tokens 4000, system 15 chars, messages: " \
      "user #{payload_text.length} (payload: #{keys.join(", ")}), assistant 10]"
    )
    expect(keys.first).to start_with("schema_subset ")
    expect(e.message.scan("[step").size).to eq(1)
  end

  it "never puts a payload value, the system prompt, or a message in the message" do
    fake.error("llm-index-ideas", status: 400)
    message = size_error(payload_text).message

    expect(message).to include("[step llm-index-ideas")
    expect(message).not_to include("SENTINEL")
  end

  it "skips the breakdown for a json block that won't parse" do
    fake.error("llm-index-ideas", status: 400)
    content = "```json\n{ SENTINEL-BROKEN\n```"

    expect(size_error(content).message).to end_with("messages: user #{content.length}, assistant 10]")
  end
end
