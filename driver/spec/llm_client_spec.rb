# frozen_string_literal: true

require "open3"
require "quaack/driver/burndown"
require "quaack/driver/llm"
require_relative "support/fake_llm"

RSpec.describe Quaack::Driver::LLM::Client do
  let(:burndown) { Quaack::Driver::Burndown.new }
  let(:fake) { FakeLLM.new }
  let(:client) { fake.client(burndown: burndown) }
  let(:messages) { [{ role: "user", content: "Propose indexes for this shape." }] }

  def ask(step = "5a-5", **)
    client.ask(step: step, messages: messages, max_tokens: 1000, **)
  end

  def llm_error(rule)
    raise_error(Quaack::Driver::LLM::Error) { |e| expect(e.rule).to eq(rule) }
  end

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

      expect { ask("6a", json: true) }.to llm_error("llm_bad_response")
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
        expect { ask(step) }.to raise_error(ArgumentError, /step that calls an LLM/)
      end
      expect(fake.asks).to eq([])
      expect(burndown.llm_calls).to eq({})
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

    it "parses the text as JSON when asked, without a schema" do
      fake.reply("6a", [{ "sql" => "SELECT 1" }])

      expect(ask("6a", json: true)).to eq([{ "sql" => "SELECT 1" }])
      expect(fake.asks.first.body).not_to have_key(:output_config)
    end

    it "fails with llm_bad_response on a reply that isn't JSON, without quoting it" do
      fake.reply("5a-5", "SENTINEL-REPLY {")

      expect { ask(schema: schema) }.to raise_error(Quaack::Driver::LLM::Error) { |e|
        expect(e.rule).to eq("llm_bad_response")
        expect(e.message).not_to include("SENTINEL-REPLY")
      }
    end
  end

  describe "replies that can't be used" do
    it "fails with llm_bad_response on a reply cut short at max_tokens" do
      fake.reply("5a-5", "CREATE INDEX ON t (", stop_reason: "max_tokens")

      expect { ask }.to llm_error("llm_bad_response")
    end

    it "fails with llm_bad_response on a refusal" do
      fake.reply("5a-5", "", stop_reason: "refusal")

      expect { ask }.to llm_error("llm_bad_response")
    end

    it "fails with llm_bad_response on a reply with no text" do
      fake.reply_blocks("5a-5", [])

      expect { ask }.to llm_error("llm_bad_response")
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

  describe "the model" do
    it "is LLM.model unless it's given, so QUAACK_MODEL reaches every call" do
      original = ENV.fetch("QUAACK_MODEL", nil)
      ENV["QUAACK_MODEL"] = "claude-from-env"
      client = described_class.new(api_key: "k", burndown: burndown, transport: fake)
      fake.reply("5a-5", "ok")
      client.ask(step: "5a-5", messages: messages, max_tokens: 10)

      expect(fake.asks.first.body[:model]).to eq("claude-from-env")
    ensure
      ENV["QUAACK_MODEL"] = original
    end

    it "sends the model it was built with" do
      fake.reply("5a-5", "ok")
      fake.client(burndown: burndown, model: "claude-other-1").ask(step: "5a-5", messages: messages, max_tokens: 10)

      expect(fake.asks.first.body[:model]).to eq("claude-other-1")
    end
  end
end

RSpec.describe Quaack::Driver::LLM do
  describe ".model" do
    it "is claude-opus-5-5 by default" do
      expect(described_class.model({}, env: {})).to eq("claude-opus-5-5")
    end

    it "takes the driver config's model over the default" do
      expect(described_class.model({ "model" => "claude-from-config" }, env: {})).to eq("claude-from-config")
    end

    it "takes QUAACK_MODEL over the config and the default" do
      env = { "QUAACK_MODEL" => "claude-from-env" }

      expect(described_class.model({ "model" => "claude-from-config" }, env: env)).to eq("claude-from-env")
      expect(described_class.model({}, env: env)).to eq("claude-from-env")
    end

    it "ignores an empty QUAACK_MODEL or config value" do
      expect(described_class.model({ "model" => "" }, env: { "QUAACK_MODEL" => "" })).to eq("claude-opus-5-5")
    end

    it "reads the process environment when no env is given" do
      original = ENV.fetch("QUAACK_MODEL", nil)
      ENV["QUAACK_MODEL"] = "claude-from-process"
      expect(described_class.model).to eq("claude-from-process")
    ensure
      ENV["QUAACK_MODEL"] = original
    end
  end

  describe "a client with no transport, which would call the real API" do
    let(:burndown) { Quaack::Driver::Burndown.new }

    def with_env(changes)
      original = changes.keys.to_h { [it, ENV.fetch(it, nil)] }
      changes.each { |k, v| ENV[k] = v }
      yield
    ensure
      original.each { |k, v| ENV[k] = v }
    end

    it "can't be built while specs run" do
      expect { described_class::Client.new(api_key: "k", burndown: burndown) }
        .to raise_error(described_class::RealClientInSpecs, /QUAACK_ALLOW_REAL_LLM/)
    end

    it "can't be built in a process that loaded RSpec, even without the helpers' marker" do
      with_env("QUAACK_SPECS" => nil) do
        expect { described_class::Client.new(api_key: "k", burndown: burndown) }
          .to raise_error(described_class::RealClientInSpecs)
      end
    end

    it "can be built in specs with the explicit opt-in" do
      with_env("QUAACK_ALLOW_REAL_LLM" => "1") do
        expect(described_class::Client.new(api_key: "k", burndown: burndown)).to be_a(described_class::Client)
      end
    end

    it "fails with llm_auth when there's no API key" do
      with_env("QUAACK_ALLOW_REAL_LLM" => "1", "ANTHROPIC_API_KEY" => nil) do
        expect { described_class::Client.new(burndown: burndown) }
          .to raise_error(described_class::Error, /\Allm_auth: .*ANTHROPIC_API_KEY/)
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

    it "can't be built in a child process a spec starts, which inherits the helpers' marker" do
      code = 'require "quaack/driver"; ' \
             'Quaack::Driver::LLM::Client.new(api_key: "k", burndown: Quaack::Driver::Burndown.new)'
      _, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", code)

      expect(status).not_to be_success
      expect(err).to include("RealClientInSpecs")
    end
  end
end
