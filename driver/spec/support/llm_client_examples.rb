# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/llm"

# The behavior every provider's adapter gives LLM::Client the same way: the
# reply's text, the burndown count, the step check, reading JSON replies,
# replies that can't be used, and the error rules. Each adapter's spec runs
# these against its own fake, which scripts answers the same way:
# `reply`, `cut_short`, `error`, `raw`, `drop`, `client`, `asks`,
# `system_prompt(ask)`, and `model(ask)`. See FakeLLM, FakeOpenAI, and
# FakeBedrock.
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

  def step_error
    "step must be a step that calls an LLM, one of " \
      "#{Quaack::Protocol::Burndown::LLM_STEPS.join(", ")}"
  end

  describe "#ask" do
    it "returns the reply's text" do
      fake.reply("llm-index-ideas", "CREATE INDEX ON orders (status)")

      expect(ask).to eq("CREATE INDEX ON orders (status)")
    end
  end

  describe "the burndown" do
    it "counts one LLM call for each ask, under its step" do
      fake.reply("llm-index-ideas", "a").reply("llm-index-ideas", "b").reply("llm-counterexamples", "c")
      ask("llm-index-ideas")
      ask("llm-index-ideas")
      ask("llm-counterexamples")

      expect(burndown.llm_calls).to eq("llm-index-ideas" => 2, "llm-counterexamples" => 1)
    end

    it "counts every attempt, since a retry is an API call too" do
      fake.error("llm-rewrites", status: 529).error("llm-rewrites", status: 429).reply("llm-rewrites", "ok")

      expect(ask("llm-rewrites")).to eq("ok")
      expect(burndown.llm_calls).to eq("llm-rewrites" => 3)
      expect(fake.asks.size).to eq(3)
    end

    it "tells its progress when each ask starts, and each attempt after the first" do
      notes = []
      client.progress = Object.new.tap { |p| p.define_singleton_method(:note) { notes << it } }
      fake.error("llm-rewrites", status: 529).error("llm-rewrites", status: 429).reply("llm-rewrites", "ok").reply(
        "llm-index-ideas", "ok"
      )
      ask("llm-rewrites")
      ask("llm-index-ideas")

      expect(notes).to eq(["Asking the LLM (llm-rewrites)", "Asking the LLM, attempt 2 (llm-rewrites)",
                           "Asking the LLM, attempt 3 (llm-rewrites)", "Asking the LLM (llm-index-ideas)"])
    end

    it "says what an ask is for when the caller does" do
      notes = []
      client.progress = Object.new.tap { |p| p.define_singleton_method(:note) { notes << it } }
      fake.reply("llm-index-ideas", "ok")
      ask("llm-index-ideas", purpose: "Asking the LLM again for replacements")

      expect(notes).to eq(["Asking the LLM again for replacements (llm-index-ideas)"])
    end

    it "counts attempts that end in an error" do
      3.times { fake.error("operator-rewrites", status: 529) }

      expect { ask("operator-rewrites") }.to llm_error("llm_unavailable")
      expect(burndown.llm_calls).to eq("operator-rewrites" => 3)
    end

    it "counts an attempt whose reply can't be used" do
      fake.reply("llm-rewrites", "not json")

      expect do
        ask("llm-rewrites", json: true)
      end.to llm_error("llm_bad_response", "llm_bad_response: the reply wasn't valid JSON")
      expect(burndown.llm_calls).to eq("llm-rewrites" => 1)
    end
  end

  describe "the step" do
    it "takes every step the protocol lists as one that calls an LLM" do
      Quaack::Protocol::Burndown::LLM_STEPS.each { fake.reply(it, it) }

      expect(Quaack::Protocol::Burndown::LLM_STEPS.map { ask(it) }).to eq(Quaack::Protocol::Burndown::LLM_STEPS)
    end

    it "refuses a step that doesn't call an LLM before making any call" do
      ["index-dedupe", "plan-pruning", "6A", :"llm-rewrites", nil].each do |step|
        expect { ask(step) }.to raise_error(ArgumentError, step_error)
      end
      expect(fake.asks).to eq([])
      expect(burndown.llm_calls).to eq({})
    end
  end

  describe "JSON replies" do
    it "returns the parsed JSON that matches the schema" do
      fake.reply("llm-index-ideas", { "ddl" => ["CREATE INDEX ON t (a)"] })

      expect(ask(schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
    end

    it "starts the system prompt with the caller's, then the JSON-only line, when there's a schema" do
      fake.reply("llm-index-ideas", { "ddl" => [] })
      ask(system: "You propose indexes.", schema: schema)

      expect(fake.system_prompt(fake.asks.first))
        .to start_with("You propose indexes.\n\n#{Quaack::Driver::LLM::Client::JSON_ONLY}")
    end

    it "leaves the system prompt as it is without a schema" do
      fake.reply("llm-rewrites", [])
      ask("llm-rewrites", system: "You rewrite SQL.", json: true)

      expect(fake.system_prompt(fake.asks.first)).to eq("You rewrite SQL.")
    end

    it "reads the JSON object out of a code fence with prose around it" do
      fake.reply("llm-index-ideas",
                 "Here you go:\n\n```json\n{\"ddl\": [\"CREATE INDEX ON t (a)\"]}\n```\n\nHope that helps.")

      expect(ask(schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
    end

    it "reads a bare JSON object followed by trailing prose" do
      fake.reply("llm-index-ideas", "{\"ddl\": []}\nThese cover the filter.")

      expect(ask(schema: schema)).to eq("ddl" => [])
    end

    it "skips a stray example object in the prose and reads the one that matches the schema" do
      fake.reply("llm-index-ideas", "Using {\"a\": 1} as shown, here are the indexes:\n\n" \
                                    "```json\n{\"ddl\": [\"CREATE INDEX ON t (a)\"]}\n```")

      expect(ask(schema: schema)).to eq("ddl" => ["CREATE INDEX ON t (a)"])
    end

    it "skips an earlier object whose required key has the wrong type" do
      fake.reply("llm-index-ideas", "For example {\"ddl\": \"one\"} is wrong. The answer: {\"ddl\": []}")

      expect(ask(schema: schema)).to eq("ddl" => [])
    end

    it "parses the text as JSON when asked, without a schema" do
      fake.reply("llm-rewrites", [{ "sql" => "SELECT 1" }])

      expect(ask("llm-rewrites", json: true)).to eq([{ "sql" => "SELECT 1" }])
    end

    it "fails with llm_bad_response on a reply that isn't the JSON asked for, without quoting it" do
      fake.reply("llm-rewrites", "SENTINEL-REPLY {")

      e = ask_error("llm-rewrites", json: true)

      expect(e.rule).to eq("llm_bad_response")
      expect(sans_sizes(e.message)).to eq("llm_bad_response: the reply wasn't valid JSON")
      # The parser's own error quotes the reply, so it isn't kept as the cause.
      expect(e.cause).to be_nil
    end
  end

  describe "replies that can't be used" do
    it "fails with llm_bad_response on a reply cut short at the token limit" do
      fake.cut_short("llm-index-ideas", "CREATE INDEX ON t (")

      e = ask_error

      expect(e.rule).to eq("llm_bad_response")
      expect(e.message).to start_with("llm_bad_response: the reply stopped for ")
    end

    it "fails with llm_bad_response on a reply body that isn't a JSON object, without quoting it" do
      fake.raw("llm-index-ideas", JSON.generate(%w[SENTINEL-BODY])).raw("llm-counterexamples", "SENTINEL-BODY not json")

      [ask_error("llm-index-ideas"), ask_error("llm-counterexamples")].each do |e|
        expect(e.rule).to eq("llm_bad_response")
        expect(e.cause).to be_nil
        expect(e.message).not_to include("SENTINEL")
      end
    end
  end

  describe "API errors" do
    it "fails with llm_rate_limited once the gem's retries run out on 429s" do
      3.times { fake.error("llm-index-ideas", status: 429) }

      expect { ask }.to llm_error("llm_rate_limited")
      expect(fake.asks.size).to eq(3)
    end

    # A dropped connection has no retry-after, so the gem backs off half a
    # second. One retry keeps the spec quick.
    it "fails with llm_unavailable once retries run out on dropped connections" do
      client = fake.client(burndown: burndown, max_retries: 1)
      2.times { fake.drop("llm-index-ideas") }

      expect { client.ask(step: "llm-index-ideas", messages: messages, max_tokens: 10) }.to llm_error("llm_unavailable")
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 2)
    end

    it "fails with llm_unavailable on a server error that persists" do
      3.times { fake.error("llm-index-ideas", status: 500) }

      expect { ask }.to llm_error("llm_unavailable")
    end

    it "fails with llm_auth on a bad key or a forbidden request, without retrying" do
      fake.error("llm-index-ideas", status: 401).error("llm-counterexamples", status: 403)

      expect { ask("llm-index-ideas") }.to llm_error("llm_auth")
      expect { ask("llm-counterexamples") }.to llm_error("llm_auth")
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 1, "llm-counterexamples" => 1)
    end

    # 408 is a timeout and 409 a lock, both passing, so the gem retries them
    # and what's left once it gives up is an API that isn't answering.
    it "fails with llm_unavailable once retries run out on 408s or 409s" do
      3.times { fake.error("llm-index-ideas", status: 408).error("llm-counterexamples", status: 409) }

      expect { ask("llm-index-ideas") }.to llm_error("llm_unavailable")
      expect { ask("llm-counterexamples") }.to llm_error("llm_unavailable")
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 3, "llm-counterexamples" => 3)
    end

    it "fails with llm_bad_request on a request the API rejects, without retrying" do
      fake.error("llm-index-ideas", status: 400).error("llm-counterexamples", status: 404)

      expect { ask("llm-index-ideas") }.to llm_error("llm_bad_request")
      expect { ask("llm-counterexamples") }.to llm_error("llm_bad_request")
      expect(fake.asks.size).to eq(2)
    end

    it "retries as many times as max_retries says" do
      client = fake.client(burndown: burndown, max_retries: 0)
      fake.error("llm-index-ideas", status: 529)

      expect { client.ask(step: "llm-index-ideas", messages: messages, max_tokens: 10) }.to llm_error("llm_unavailable")
      expect(fake.asks.size).to eq(1)
    end

    it "keeps the API key out of its error messages" do
      client = fake.client(burndown: burndown, api_key: "SENTINEL-KEY")
      # Some APIs, such as OpenAI's, quote a refused key back in the body.
      fake.error("llm-index-ideas", status: 401, message: "Incorrect API key provided: SENTINEL-KEY")
      [400, 429, 429, 429].each { fake.error("llm-index-ideas", status: it) }

      seen = Array.new(3) do
        client.ask(step: "llm-index-ideas", messages: messages, max_tokens: 10)
      rescue Quaack::Driver::LLM::Error => e
        e.message
      end

      expect(seen).to match([/\Allm_auth: /, /\Allm_bad_request: /, /\Allm_rate_limited: /])
      expect(seen.join).not_to include("SENTINEL-KEY")
    end

    # A crash report prints the whole cause chain, so a refused key the API
    # quotes back mustn't be in any of it.
    it "keeps a key the API quotes back out of an llm_auth's whole cause chain" do
      [401, 403].each do |status|
        fake.error("llm-index-ideas", status: status, message: "Incorrect API key provided: SENTINEL-KEY")

        e = ask_error

        expect(e.rule).to eq("llm_auth")
        expect(error_text(e)).to include("(#{status})")
        expect(error_text(e)).not_to include("SENTINEL-KEY")
      end
    end

    it "checks the whole cause chain, so a planted key in a cause would show" do
      planted = begin
        begin
          raise "SENTINEL-KEY"
        rescue StandardError
          raise Quaack::Driver::LLM::Error.new("llm_auth", "the API refused the key (401)")
        end
      rescue Quaack::Driver::LLM::Error => e
        e
      end

      expect(error_text(planted)).to include("SENTINEL-KEY")
    end
  end

  describe "the settings" do
    it "take a model given over the settings'" do
      fake.reply("llm-index-ideas", "ok")
      fake.client(burndown: burndown, model: "other-model-1").ask(step: "llm-index-ideas", messages: messages,
                                                                  max_tokens: 10)

      expect(fake.model(fake.asks.first)).to eq("other-model-1")
    end
  end
end
