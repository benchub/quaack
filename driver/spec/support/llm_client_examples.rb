# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/llm"

# The behavior every provider's adapter gives LLM::Client the same way: the
# reply's text, the burndown count, the step check, reading JSON replies,
# replies that can't be used, and the error rules. Each adapter's spec runs
# these against its own fake, which scripts answers the same way:
# `reply`, `cut_short`, `error`, `raw`, `drop`, `client`, `asks`, and
# `system_prompt(ask)`. See FakeLLM and FakeOpenAI.
#
# The including group defines `fake`.
RSpec.shared_examples "an LLM client" do
  let(:burndown) { Quaack::Driver::Burndown.new }
  let(:client) { fake.client(burndown: burndown) }
  let(:messages) { [{ role: "user", content: "Propose indexes for this shape." }] }
  let(:schema) do
    { type: "object", properties: { ddl: { type: "array", items: { type: "string" } } }, required: ["ddl"],
      additionalProperties: false }
  end

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

  def step_error
    "step must be a step that calls an LLM, one of " \
      "#{Quaack::Protocol::Burndown::LLM_STEPS.join(", ")}"
  end

  describe "#ask" do
    it "returns the reply's text" do
      fake.reply("5a-5", "CREATE INDEX ON orders (status)")

      expect(ask).to eq("CREATE INDEX ON orders (status)")
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

      expect { ask("6a", json: true) }.to llm_error("llm_bad_response", "llm_bad_response: the reply wasn't valid JSON")
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
  end

  describe "JSON replies" do
    it "returns the parsed JSON that matches the schema" do
      fake.reply("5a-5", { "ddl" => ["CREATE INDEX ON t (a)"] })

      expect(ask(schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
    end

    it "starts the system prompt with the caller's, then the JSON-only line, when there's a schema" do
      fake.reply("5a-5", { "ddl" => [] })
      ask(system: "You propose indexes.", schema: schema)

      expect(fake.system_prompt(fake.asks.first))
        .to start_with("You propose indexes.\n\n#{Quaack::Driver::LLM::Client::JSON_ONLY}")
    end

    it "leaves the system prompt as it is without a schema" do
      fake.reply("6a", [])
      ask("6a", system: "You rewrite SQL.", json: true)

      expect(fake.system_prompt(fake.asks.first)).to eq("You rewrite SQL.")
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

    it "parses the text as JSON when asked, without a schema" do
      fake.reply("6a", [{ "sql" => "SELECT 1" }])

      expect(ask("6a", json: true)).to eq([{ "sql" => "SELECT 1" }])
    end

    it "fails with llm_bad_response on a reply that isn't the JSON asked for, without quoting it" do
      fake.reply("6a", "SENTINEL-REPLY {")

      e = ask_error("6a", json: true)

      expect(e.rule).to eq("llm_bad_response")
      expect(e.message).to eq("llm_bad_response: the reply wasn't valid JSON")
      # The parser's own error quotes the reply, so it isn't kept as the cause.
      expect(e.cause).to be_nil
    end
  end

  describe "replies that can't be used" do
    it "fails with llm_bad_response on a reply cut short at the token limit" do
      fake.cut_short("5a-5", "CREATE INDEX ON t (")

      e = ask_error

      expect(e.rule).to eq("llm_bad_response")
      expect(e.message).to start_with("llm_bad_response: the reply stopped for ")
    end

    it "fails with llm_bad_response on a reply body that isn't a JSON object, without quoting it" do
      fake.raw("5a-5", JSON.generate(%w[SENTINEL-BODY])).raw("10a", "SENTINEL-BODY not json")

      [ask_error("5a-5"), ask_error("10a")].each do |e|
        expect(e.rule).to eq("llm_bad_response")
        expect(e.cause).to be_nil
        expect(e.message).not_to include("SENTINEL")
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
      client = fake.client(burndown: burndown, api_key: "SENTINEL-KEY")
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

  describe "the settings" do
    it "take a model given over the settings'" do
      fake.reply("5a-5", "ok")
      fake.client(burndown: burndown, model: "other-model-1").ask(step: "5a-5", messages: messages, max_tokens: 10)

      expect(fake.asks.first.body[:model]).to eq("other-model-1")
    end
  end
end
