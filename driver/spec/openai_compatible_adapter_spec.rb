# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/llm"
require_relative "support/fake_openai"
require_relative "support/llm_client_examples"

# The OpenAI-compatible adapter behind LLM::Client: Chat Completions, through
# the openai gem, at the settings' base URL. The behavior every adapter
# shares is in support/llm_client_examples.rb.
RSpec.describe "the OpenAI-compatible adapter" do
  it_behaves_like "an LLM client" do
    let(:fake) { FakeOpenAI.new }
  end

  let(:burndown) { Quaack::Driver::Burndown.new }
  let(:fake) { FakeOpenAI.new }
  let(:client) { fake.client(burndown: burndown) }
  let(:messages) { [{ role: "user", content: "Propose indexes for this shape." }] }
  let(:schema) do
    { type: "object", properties: { ddl: { type: "array", items: { type: "string" } } }, required: ["ddl"],
      additionalProperties: false }
  end
  let(:json_only) { Quaack::Driver::LLM::Client::JSON_ONLY }

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

  def schema_line = "The JSON object must match this JSON schema: #{JSON.generate(schema)}"
  def response_format = { type: "json_schema", json_schema: { name: "reply", schema: schema } }
  def no_match = "llm_bad_response: the reply didn't match the schema"

  describe "the request" do
    it "sends the model, the system prompt as the first message, the messages, and the token limit" do
      fake.reply("llm-rewrites", "ok")
      client.ask(step: "llm-rewrites", system: "You rewrite SQL.", messages: messages, max_tokens: 321)

      expect(fake.asks.map(&:body)).to eq([{ model: "fake-model", max_completion_tokens: 321,
                                             messages: [{ role: "system", content: "You rewrite SQL." }, *messages] }])
    end

    it "sends no system message when there's no system prompt" do
      fake.reply("llm-rewrites", "ok")
      ask("llm-rewrites")

      expect(fake.asks.first.body[:messages]).to eq(messages)
    end

    it "keeps the conversation's turns, in order" do
      turns = [{ role: "user", content: "a" }, { role: "assistant", content: "b" }, { role: "user", content: "c" }]
      fake.reply("llm-rewrites", "ok")
      client.ask(step: "llm-rewrites", messages: turns, max_tokens: 10)

      expect(fake.asks.first.body[:messages]).to eq(turns)
    end

    it "goes to the settings' base URL" do
      fake.reply("llm-rewrites", "ok")
      ask("llm-rewrites")

      expect(fake.asks.map(&:url)).to eq(["https://llm.example.com/v1/chat/completions"])
    end

    it "goes to Groq's OpenAI-compatible endpoint when that's the base URL" do
      settings = FakeOpenAI.settings("base_url" => "https://api.groq.com/openai/v1")
      fake.reply("llm-rewrites", "ok")
      fake.client(burndown:, settings:).ask(step: "llm-rewrites", messages: messages, max_tokens: 10)

      expect(fake.asks.map(&:url)).to eq(["https://api.groq.com/openai/v1/chat/completions"])
    end

    it "sends the settings' model" do
      settings = FakeOpenAI.settings(model: "llama-3.3-70b-versatile")
      fake.reply("llm-rewrites", "ok")
      Quaack::Driver::LLM::Client.new(settings:, api_key: "k", burndown:, transport: fake)
                                 .ask(step: "llm-rewrites", messages: messages, max_tokens: 10)

      expect(fake.asks.first.body[:model]).to eq("llama-3.3-70b-versatile")
    end
  end

  describe "a schema" do
    it "asks for json_schema output, and puts the schema in the system prompt too" do
      fake.reply("llm-index-ideas", { "ddl" => ["CREATE INDEX ON t (a)"] })

      expect(ask(system: "You propose indexes.", schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
      expect(fake.asks.first.body[:response_format]).to eq(response_format)
      expect(fake.system_prompt(fake.asks.first)).to eq("You propose indexes.\n\n#{json_only}\n\n#{schema_line}")
    end

    it "sends no response_format without a schema, even for JSON" do
      fake.reply("llm-rewrites", [])
      ask("llm-rewrites", json: true)

      expect(fake.asks.first.body).not_to have_key(:response_format)
    end

    # A provider or model that can't hold a reply to a schema rejects the
    # request. The prompt already carries the schema, and the reply is
    # checked, so the ask goes again without response_format.
    [400, 422].each do |status|
      it "asks again without response_format when the API rejects it with #{status}" do
        fake.error("llm-index-ideas", status: status, param: "response_format").reply("llm-index-ideas",
                                                                                      { "ddl" => [] })

        expect(ask(schema: schema)).to eq("ddl" => [])
        expect(fake.asks.map { it.body.key?(:response_format) }).to eq([true, false])
        expect(fake.system_prompt(fake.asks.last)).to eq("#{json_only}\n\n#{schema_line}")
        expect(burndown.llm_calls).to eq("llm-index-ideas" => 2)
      end
    end

    it "stops sending response_format once the API has rejected it and the ask without it worked" do
      fake.error("llm-index-ideas", status: 400, param: "response_format")
          .reply("llm-index-ideas", { "ddl" => [] }).reply("llm-index-ideas", { "ddl" => [] })
      ask(schema: schema)
      ask(schema: schema)

      expect(fake.asks.map { it.body.key?(:response_format) }).to eq([true, false, false])
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 3)
    end

    it "asks again without response_format when the rejection's message names it, with no param" do
      fake.error("llm-index-ideas", status: 400, message: "response_format json_schema isn't supported")
          .reply("llm-index-ideas", { "ddl" => [] })

      expect(ask(schema: schema)).to eq("ddl" => [])
      expect(fake.asks.map { it.body.key?(:response_format) }).to eq([true, false])
    end

    # A 400 for something else, such as a context that's too long, or a
    # schema-validation miss like Groq's json_validate_failed, isn't the API
    # refusing response_format.
    [400, 422].each do |status|
      it "doesn't ask again on a #{status} that isn't about response_format, and keeps sending it" do
        fake.error("llm-index-ideas", status: status, message: "context too long", param: "messages")
            .error("llm-index-ideas", status: status, message: "json_validate_failed")
            .reply("llm-index-ideas", { "ddl" => [] })

        expect(ask_error(schema: schema).rule).to eq("llm_bad_request")
        expect(ask_error(schema: schema).rule).to eq("llm_bad_request")
        expect(ask(schema: schema)).to eq("ddl" => [])
        expect(fake.asks.map { it.body.key?(:response_format) }).to eq([true, true, true])
        expect(burndown.llm_calls).to eq("llm-index-ideas" => 3)
      end
    end

    it "doesn't ask again without response_format when 429s outlast the retries" do
      3.times { fake.error("llm-index-ideas", status: 429) }

      expect(ask_error(schema: schema).rule).to eq("llm_rate_limited")
      expect(fake.asks.map { it.body.key?(:response_format) }).to eq([true, true, true])
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 3)
    end

    it "doesn't ask again when the reply was cut short, with no re-ask either" do
      fake.cut_short("llm-index-ideas", '{"ddl": ["CREATE')

      e = ask_error(schema: schema)

      expect(sans_sizes(e.message)).to eq("llm_bad_response: the reply stopped for length")
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 1)
    end

    it "fails with llm_bad_request when the ask without response_format is rejected too" do
      fake.error("llm-index-ideas", status: 400, param: "response_format").error("llm-index-ideas", status: 400)

      expect { ask(schema: schema) }.to raise_error(Quaack::Driver::LLM::Error) { expect(it.rule).to eq("llm_bad_request") }
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 2)
    end

    it "keeps sending response_format when the ask without it failed too" do
      fake.error("llm-index-ideas", status: 400, param: "response_format").error("llm-index-ideas", status: 400)
          .reply("llm-index-ideas", { "ddl" => [] })
      ask_error(schema: schema)
      ask(schema: schema)

      expect(fake.asks.map { it.body.key?(:response_format) }).to eq([true, false, true])
    end

    it "puts the provider's error message in a rejected request's detail" do
      fake.error_body("llm-index-ideas", status: 400,
                                         body: { error: { message: "sentinel reason", type: "invalid_request_error" } })

      expect(sans_sizes(ask_error.message)).to match(/\Allm_bad_request: .*sentinel reason\z/)
    end

    it "puts the whole JSON body in the detail when its error has no message" do
      fake.error_body("llm-index-ideas", status: 400, body: { error: { type: "sentinel_type" } })

      expect(sans_sizes(ask_error.message)).to end_with(JSON.generate("error" => { "type" => "sentinel_type" }))
    end

    it "puts a text body in the detail as it is" do
      fake.error_body("llm-index-ideas", status: 400, body: "sentinel text body")

      expect(sans_sizes(ask_error.message)).to end_with("sentinel text body")
    end

    it "keeps an llm_auth detail to the status, without the body" do
      fake.error_body("llm-index-ideas", status: 401, body: { error: { message: "sentinel key sk-123" } })

      expect(sans_sizes(ask_error.message)).to eq("llm_auth: the API refused the key (401)")
    end

    it "doesn't ask again on a rejected request that had no schema" do
      fake.error("llm-index-ideas", status: 400)

      expect(ask_error.rule).to eq("llm_bad_request")
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 1)
    end
  end

  # The provider may take response_format and still not hold the reply to
  # the schema, so a reply that doesn't match is asked for once more, with
  # what was wrong, and each attempt counts.
  describe "a reply that doesn't match the schema" do
    let(:reask) do
      "That reply couldn't be used: the reply didn't match the schema. " \
        "Reply again with only the JSON object, matching the schema."
    end

    it "is asked for once more, with the reply and what was wrong with it" do
      fake.reply("llm-index-ideas", { "indexes" => [] }).reply("llm-index-ideas",
                                                               { "ddl" => ["CREATE INDEX ON t (a)"] })

      expect(ask(schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
      expect(fake.asks.last.body[:messages].drop(1))
        .to eq([*messages, { role: "assistant", content: '{"indexes":[]}' }, { role: "user", content: reask }])
      expect(fake.system_prompt(fake.asks.last)).to eq(fake.system_prompt(fake.asks.first))
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 2)
    end

    it "is asked for once more when it isn't JSON at all" do
      fake.reply("llm-index-ideas", "no JSON here").reply("llm-index-ideas", { "ddl" => [] })

      expect(ask(schema: schema)).to eq("ddl" => [])
      expect(fake.asks.last.body[:messages].last[:content])
        .to eq("That reply couldn't be used: the reply wasn't valid JSON. " \
               "Reply again with only the JSON object, matching the schema.")
    end

    it "fails with llm_bad_response when the second reply doesn't match either, asking no third time" do
      fake.reply("llm-index-ideas", { "indexes" => [] }).reply("llm-index-ideas", { "ddl" => "one" })

      e = ask_error(schema: schema)

      expect(e.rule).to eq("llm_bad_response")
      expect(sans_sizes(e.message)).to eq(no_match)
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 2)
    end

    it "isn't asked for again when no schema was given" do
      fake.reply("llm-rewrites", "not json")

      expect(ask_error("llm-rewrites", json: true).rule).to eq("llm_bad_response")
      expect(burndown.llm_calls).to eq("llm-rewrites" => 1)
    end
  end

  describe "replies that can't be used" do
    def stopped_for(reason) = "llm_bad_response: the reply stopped for #{reason}"

    # Only a reply that finished on its own, or at a stop sequence, is whole.
    %w[length content_filter tool_calls function_call brand_new_reason].each do |reason|
      it "fails with llm_bad_response on finish reason #{reason}" do
        fake.reply("llm-index-ideas", "CREATE INDEX ON t (a)", finish_reason: reason)

        expect(sans_sizes(ask_error.message)).to eq(stopped_for(reason))
      end
    end

    it "fails with llm_bad_response on a reply with no content" do
      fake.reply_message("llm-index-ideas", { role: "assistant", content: nil })

      expect(sans_sizes(ask_error.message)).to eq("llm_bad_response: the reply had no text")
    end

    it "fails with llm_bad_response on a refusal, without quoting it" do
      fake.reply_message("llm-index-ideas", { role: "assistant", content: nil, refusal: "SENTINEL-REFUSAL" })

      e = ask_error

      expect(sans_sizes(e.message)).to eq("llm_bad_response: the reply was a refusal")
    end

    it "fails with llm_bad_response on a completion with no choices" do
      fake.raw("llm-index-ideas",
               JSON.generate(id: "c", object: "chat.completion", created: 0, model: "m", choices: []))

      expect(sans_sizes(ask_error.message)).to eq("llm_bad_response: the reply had no choices")
    end

    # Some proxies, such as OpenRouter for an upstream failure, answer 200
    # with an error object in place of a completion.
    it "fails with llm_bad_response on a 200 whose body is an error, not a completion, without quoting it" do
      fake.raw("llm-rewrites", JSON.generate(error: { message: "SENTINEL-UPSTREAM", code: 502 }))

      e = ask_error("llm-rewrites")

      expect(e.rule).to eq("llm_bad_response")
      expect(sans_sizes(e.message)).to eq("llm_bad_response: the reply had no choices")
      expect(e.message).not_to include("SENTINEL")
      expect(e.cause).to be_nil
      expect(burndown.llm_calls).to eq("llm-rewrites" => 1)
    end

    # The gem raises its ConversionError for these, whose message quotes
    # what it couldn't convert.
    it "fails with llm_bad_response on a completion whose choices are null, without keeping the gem's error" do
      fake.raw("llm-index-ideas",
               JSON.generate(id: "c", object: "chat.completion", created: 0, model: "m", choices: nil))

      e = ask_error

      expect(sans_sizes(e.message)).to eq("llm_bad_response: the reply couldn't be read as a message")
      expect(e.cause).to be_nil
    end

    it "fails with llm_bad_response on content that isn't text, without quoting it" do
      fake.reply_message("llm-index-ideas", { role: "assistant", content: { text: "SENTINEL-CONTENT" } })

      e = ask_error

      expect(sans_sizes(e.message)).to eq("llm_bad_response: the reply couldn't be read as a message")
      expect(e.cause).to be_nil
    end

    it "fails with llm_bad_response on a reply the gem can't read as a completion" do
      fake.raw("llm-index-ideas",
               JSON.generate(id: "c", object: "chat.completion", created: 0, model: "m",
                             choices: [{ index: 0, message: "SENTINEL-MESSAGE", finish_reason: "stop" }]))

      e = ask_error

      expect(sans_sizes(e.message)).to eq("llm_bad_response: the reply couldn't be read as a message")
      expect(e.cause).to be_nil
    end
  end

  describe "the credentials" do
    # FakeOpenAI never records headers, so this transport looks only at the
    # one that carries the key, and answers every attempt.
    let(:key_transport) do
      Class.new do
        attr_reader :seen

        def initialize = @seen = []

        def call(request, step:)
          @seen << request.headers.slice("authorization")
          body = { id: "c", object: "chat.completion", created: 0, model: "m",
                   choices: [{ index: 0, message: { role: "assistant", content: step }, finish_reason: "stop" }] }
          OpenAI::HTTPClient::Response.new(status: 200, headers: { "content-type" => "application/json" },
                                           body: JSON.generate(body))
        end
      end.new
    end

    def build(settings = FakeOpenAI.settings, **)
      Quaack::Driver::LLM::Client.new(settings:, burndown:, transport: key_transport, **)
    end

    def ask_with(client) = client.ask(step: "llm-rewrites", messages: messages, max_tokens: 10)
    def groq_settings = FakeOpenAI.settings("api_key_env" => "QUAACK_SPEC_GROQ_KEY")

    it "sends OPENAI_API_KEY as a bearer token when the settings name no variable" do
      with_env("OPENAI_API_KEY" => "SENTINEL-OPENAI") { ask_with(build) }

      expect(key_transport.seen).to eq([{ "authorization" => "Bearer SENTINEL-OPENAI" }])
    end

    it "sends the key from the variable api_key_env names, over OPENAI_API_KEY" do
      with_env("OPENAI_API_KEY" => "SENTINEL-OPENAI", "QUAACK_SPEC_GROQ_KEY" => "SENTINEL-GROQ") do
        ask_with(build(groq_settings))
      end

      expect(key_transport.seen).to eq([{ "authorization" => "Bearer SENTINEL-GROQ" }])
    end

    it "sends a key it was given over the variable's" do
      with_env("QUAACK_SPEC_GROQ_KEY" => "SENTINEL-GROQ") { ask_with(build(groq_settings, api_key: "SENTINEL-GIVEN")) }

      expect(key_transport.seen).to eq([{ "authorization" => "Bearer SENTINEL-GIVEN" }])
    end

    it "fails with llm_auth before any attempt, naming the variable, when it's unset" do
      with_env("OPENAI_API_KEY" => "SENTINEL-OPENAI", "QUAACK_SPEC_GROQ_KEY" => nil) do
        expect { build(groq_settings) }
          .to raise_error(Quaack::Driver::LLM::Error, "llm_auth: QUAACK_SPEC_GROQ_KEY isn't set")
      end
      with_env("OPENAI_API_KEY" => nil) do
        expect { build }.to raise_error(Quaack::Driver::LLM::Error, "llm_auth: OPENAI_API_KEY isn't set")
      end
      expect(key_transport.seen).to eq([])
      expect(burndown.llm_calls).to eq({})
    end

    it "fails with llm_auth before any attempt, naming the variable, when it's set but empty" do
      with_env("OPENAI_API_KEY" => "SENTINEL-OPENAI", "QUAACK_SPEC_GROQ_KEY" => "") do
        expect { build(groq_settings) }
          .to raise_error(Quaack::Driver::LLM::Error, "llm_auth: QUAACK_SPEC_GROQ_KEY is set but empty")
      end
      with_env("OPENAI_API_KEY" => "") do
        expect { build }.to raise_error(Quaack::Driver::LLM::Error, "llm_auth: OPENAI_API_KEY is set but empty")
      end
      expect(key_transport.seen).to eq([])
      expect(burndown.llm_calls).to eq({})
    end

    it "fails with llm_auth on a refused key without quoting the API's message, which can echo the key" do
      fake.error("llm-index-ideas", status: 401)

      expect(sans_sizes(ask_error.message)).to eq("llm_auth: the API refused the key (401)")
    end
  end

  # The gem reads OPENAI_BASE_URL, OPENAI_ORG_ID, OPENAI_PROJECT_ID, and
  # OPENAI_CUSTOM_HEADERS. Only driver.json picks where asks go, and only
  # OpenAI hears the OpenAI settings.
  describe "the gem's OPENAI_ variables" do
    let(:header_transport) do
      Class.new do
        attr_reader :seen

        def initialize = @seen = []

        def call(request, step:)
          @seen << { url: request.url.to_s, headers: request.headers.except("authorization") }
          body = { id: "c", object: "chat.completion", created: 0, model: "m",
                   choices: [{ index: 0, message: { role: "assistant", content: step }, finish_reason: "stop" }] }
          OpenAI::HTTPClient::Response.new(status: 200, headers: { "content-type" => "application/json" },
                                           body: JSON.generate(body))
        end
      end.new
    end
    let(:openai_env) do
      { "OPENAI_ORG_ID" => "SENTINEL-ORG", "OPENAI_PROJECT_ID" => "SENTINEL-PROJECT",
        "OPENAI_CUSTOM_HEADERS" => "X-Sentinel: SENTINEL-HEADER",
        "OPENAI_BASE_URL" => "https://sentinel.example.com/v1" }
    end

    def openai_settings(block = {})
      Quaack::Driver::LLM.settings({ "provider" => "openai_compatible", "model" => "m", **block }, env: {})
    end

    def ask_through(settings)
      with_env(openai_env) do
        Quaack::Driver::LLM::Client.new(settings:, api_key: "k", burndown:, transport: header_transport)
      end.ask(step: "llm-rewrites", messages: messages, max_tokens: 10)
      header_transport.seen.last
    end

    it "go to OpenAI's own API without a base_url, ignoring OPENAI_BASE_URL" do
      seen = ask_through(openai_settings)

      expect(seen[:url]).to eq("https://api.openai.com/v1/chat/completions")
      expect(seen[:headers]).to include("openai-organization" => "SENTINEL-ORG",
                                        "openai-project" => "SENTINEL-PROJECT", "x-sentinel" => "SENTINEL-HEADER")
    end

    it "go to OpenAI's own API at a base_url whose host differs only in case" do
      seen = ask_through(openai_settings("base_url" => "https://API.OpenAI.com/v1"))

      expect(seen[:headers]).to include("openai-organization" => "SENTINEL-ORG",
                                        "openai-project" => "SENTINEL-PROJECT", "x-sentinel" => "SENTINEL-HEADER")
    end

    # Hosts that start with OpenAI's, or put it before an @, aren't OpenAI's.
    %w[https://api.openai.com.evil.example/v1 https://api.openai.com@evil.example/v1].each do |url|
      it "never go to a lookalike host, #{url}" do
        seen = ask_through(openai_settings("base_url" => url))

        expect(seen[:url]).to include("evil.example")
        expect(seen[:headers].to_s).not_to include("SENTINEL")
      end
    end

    it "never go to another provider's base_url" do
      seen = ask_through(openai_settings("base_url" => "https://api.groq.com/openai/v1"))

      expect(seen[:url]).to eq("https://api.groq.com/openai/v1/chat/completions")
      expect(seen[:headers].to_s).not_to include("SENTINEL")
    end
  end

  describe "a client with no transport, which would call the real API" do
    it "can't be built while specs run" do
      expect { Quaack::Driver::LLM::Client.new(settings: FakeOpenAI.settings, api_key: "k", burndown:) }
        .to raise_error(Quaack::Driver::LLM::RealClientInSpecs)
    end
  end
end
