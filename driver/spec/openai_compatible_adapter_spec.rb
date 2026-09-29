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

  def schema_line = "The JSON object must match this JSON schema: #{JSON.generate(schema)}"
  def response_format = { type: "json_schema", json_schema: { name: "reply", schema: schema } }
  def no_match = "llm_bad_response: the reply didn't match the schema"

  describe "the request" do
    it "sends the model, the system prompt as the first message, the messages, and the token limit" do
      fake.reply("6a", "ok")
      client.ask(step: "6a", system: "You rewrite SQL.", messages: messages, max_tokens: 321)

      expect(fake.asks.map(&:body)).to eq([{ model: "fake-model", max_completion_tokens: 321,
                                             messages: [{ role: "system", content: "You rewrite SQL." }, *messages] }])
    end

    it "sends no system message when there's no system prompt" do
      fake.reply("6a", "ok")
      ask("6a")

      expect(fake.asks.first.body[:messages]).to eq(messages)
    end

    it "keeps the conversation's turns, in order" do
      turns = [{ role: "user", content: "a" }, { role: "assistant", content: "b" }, { role: "user", content: "c" }]
      fake.reply("6a", "ok")
      client.ask(step: "6a", messages: turns, max_tokens: 10)

      expect(fake.asks.first.body[:messages]).to eq(turns)
    end

    it "goes to the settings' base URL" do
      fake.reply("6a", "ok")
      ask("6a")

      expect(fake.asks.map(&:url)).to eq(["https://llm.example.com/v1/chat/completions"])
    end

    it "goes to Groq's OpenAI-compatible endpoint when that's the base URL" do
      settings = FakeOpenAI.settings("base_url" => "https://api.groq.com/openai/v1")
      fake.reply("6a", "ok")
      fake.client(burndown:, settings:).ask(step: "6a", messages: messages, max_tokens: 10)

      expect(fake.asks.map(&:url)).to eq(["https://api.groq.com/openai/v1/chat/completions"])
    end

    it "sends the settings' model" do
      settings = FakeOpenAI.settings(model: "llama-3.3-70b-versatile")
      fake.reply("6a", "ok")
      Quaack::Driver::LLM::Client.new(settings:, api_key: "k", burndown:, transport: fake)
                                 .ask(step: "6a", messages: messages, max_tokens: 10)

      expect(fake.asks.first.body[:model]).to eq("llama-3.3-70b-versatile")
    end
  end

  describe "a schema" do
    it "asks for json_schema output, and puts the schema in the system prompt too" do
      fake.reply("5a-5", { "ddl" => ["CREATE INDEX ON t (a)"] })

      expect(ask(system: "You propose indexes.", schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
      expect(fake.asks.first.body[:response_format]).to eq(response_format)
      expect(fake.system_prompt(fake.asks.first)).to eq("You propose indexes.\n\n#{json_only}\n\n#{schema_line}")
    end

    it "sends no response_format without a schema, even for JSON" do
      fake.reply("6a", [])
      ask("6a", json: true)

      expect(fake.asks.first.body).not_to have_key(:response_format)
    end

    # A provider or model that can't hold a reply to a schema rejects the
    # request. The prompt already carries the schema, and the reply is
    # checked, so the ask goes again without response_format.
    [400, 422].each do |status|
      it "asks again without response_format when the API rejects it with #{status}" do
        fake.error("5a-5", status: status, param: "response_format").reply("5a-5", { "ddl" => [] })

        expect(ask(schema: schema)).to eq("ddl" => [])
        expect(fake.asks.map { it.body.key?(:response_format) }).to eq([true, false])
        expect(fake.system_prompt(fake.asks.last)).to eq("#{json_only}\n\n#{schema_line}")
        expect(burndown.llm_calls).to eq("5a-5" => 2)
      end
    end

    it "stops sending response_format once the API has rejected it and the ask without it worked" do
      fake.error("5a-5", status: 400).reply("5a-5", { "ddl" => [] }).reply("5a-5", { "ddl" => [] })
      ask(schema: schema)
      ask(schema: schema)

      expect(fake.asks.map { it.body.key?(:response_format) }).to eq([true, false, false])
      expect(burndown.llm_calls).to eq("5a-5" => 3)
    end

    it "fails with llm_bad_request when the ask without response_format is rejected too" do
      fake.error("5a-5", status: 400).error("5a-5", status: 400)

      expect { ask(schema: schema) }.to raise_error(Quaack::Driver::LLM::Error) { expect(it.rule).to eq("llm_bad_request") }
      expect(burndown.llm_calls).to eq("5a-5" => 2)
    end

    it "keeps sending response_format when the ask without it failed too" do
      fake.error("5a-5", status: 400).error("5a-5", status: 400).reply("5a-5", { "ddl" => [] })
      ask_error(schema: schema)
      ask(schema: schema)

      expect(fake.asks.map { it.body.key?(:response_format) }).to eq([true, false, true])
    end

    it "doesn't ask again on a rejected request that had no schema" do
      fake.error("5a-5", status: 400)

      expect(ask_error.rule).to eq("llm_bad_request")
      expect(burndown.llm_calls).to eq("5a-5" => 1)
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
      fake.reply("5a-5", { "indexes" => [] }).reply("5a-5", { "ddl" => ["CREATE INDEX ON t (a)"] })

      expect(ask(schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
      expect(fake.asks.last.body[:messages].drop(1))
        .to eq([*messages, { role: "assistant", content: '{"indexes":[]}' }, { role: "user", content: reask }])
      expect(fake.system_prompt(fake.asks.last)).to eq(fake.system_prompt(fake.asks.first))
      expect(burndown.llm_calls).to eq("5a-5" => 2)
    end

    it "is asked for once more when it isn't JSON at all" do
      fake.reply("5a-5", "no JSON here").reply("5a-5", { "ddl" => [] })

      expect(ask(schema: schema)).to eq("ddl" => [])
      expect(fake.asks.last.body[:messages].last[:content])
        .to eq("That reply couldn't be used: the reply wasn't valid JSON. " \
               "Reply again with only the JSON object, matching the schema.")
    end

    it "fails with llm_bad_response when the second reply doesn't match either, asking no third time" do
      fake.reply("5a-5", { "indexes" => [] }).reply("5a-5", { "ddl" => "one" })

      e = ask_error(schema: schema)

      expect(e.rule).to eq("llm_bad_response")
      expect(e.message).to eq(no_match)
      expect(burndown.llm_calls).to eq("5a-5" => 2)
    end

    it "isn't asked for again when no schema was given" do
      fake.reply("6a", "not json")

      expect(ask_error("6a", json: true).rule).to eq("llm_bad_response")
      expect(burndown.llm_calls).to eq("6a" => 1)
    end
  end

  describe "replies that can't be used" do
    def stopped_for(reason) = "llm_bad_response: the reply stopped for #{reason}"

    # Only a reply that finished on its own, or at a stop sequence, is whole.
    %w[length content_filter tool_calls function_call brand_new_reason].each do |reason|
      it "fails with llm_bad_response on finish reason #{reason}" do
        fake.reply("5a-5", "CREATE INDEX ON t (a)", finish_reason: reason)

        expect(ask_error.message).to eq(stopped_for(reason))
      end
    end

    it "fails with llm_bad_response on a reply with no content" do
      fake.reply_message("5a-5", { role: "assistant", content: nil })

      expect(ask_error.message).to eq("llm_bad_response: the reply had no text")
    end

    it "fails with llm_bad_response on a refusal, without quoting it" do
      fake.reply_message("5a-5", { role: "assistant", content: nil, refusal: "SENTINEL-REFUSAL" })

      e = ask_error

      expect(e.message).to eq("llm_bad_response: the reply was a refusal")
    end

    it "fails with llm_bad_response on a completion with no choices" do
      fake.raw("5a-5", JSON.generate(id: "c", object: "chat.completion", created: 0, model: "m", choices: []))

      expect(ask_error.message).to eq("llm_bad_response: the reply had no choices")
    end

    it "fails with llm_bad_response on a reply the gem can't read as a completion" do
      fake.raw("5a-5", JSON.generate(id: "c", object: "chat.completion", created: 0, model: "m",
                                     choices: [{ index: 0, message: "SENTINEL-MESSAGE", finish_reason: "stop" }]))

      e = ask_error

      expect(e.message).to eq("llm_bad_response: the reply couldn't be read as a message")
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

    def ask_with(client) = client.ask(step: "6a", messages: messages, max_tokens: 10)
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

    it "fails with llm_auth before any attempt, naming the variable, when it's unset or empty" do
      [nil, ""].each do |value|
        with_env("OPENAI_API_KEY" => "SENTINEL-OPENAI", "QUAACK_SPEC_GROQ_KEY" => value) do
          expect { build(groq_settings) }
            .to raise_error(Quaack::Driver::LLM::Error, "llm_auth: QUAACK_SPEC_GROQ_KEY isn't set")
        end
        with_env("OPENAI_API_KEY" => value) do
          expect { build }.to raise_error(Quaack::Driver::LLM::Error, "llm_auth: OPENAI_API_KEY isn't set")
        end
      end
      expect(key_transport.seen).to eq([])
      expect(burndown.llm_calls).to eq({})
    end

    it "fails with llm_auth on a refused key without quoting the API's message, which can echo the key" do
      fake.error("5a-5", status: 401)

      expect(ask_error.message).to eq("llm_auth: the API refused the key (401)")
    end
  end

  describe "a client with no transport, which would call the real API" do
    it "can't be built while specs run" do
      expect { Quaack::Driver::LLM::Client.new(settings: FakeOpenAI.settings, api_key: "k", burndown:) }
        .to raise_error(Quaack::Driver::LLM::RealClientInSpecs)
    end
  end
end
