# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/generator_three"
require_relative "support/fake_llm"
require_relative "support/routers"

RSpec.describe Quaack::Driver::GeneratorThree do
  include Routers

  let(:fake) { FakeLLM.new }
  let(:client) { router_of(fake) }
  let(:payload) do
    { "query" => "SELECT * FROM public.customers WHERE email LIKE $1", "placeholders" => {},
      "plan" => {}, "schema" => "CREATE TABLE public.customers (email text)", "mechanical_results" => [],
      "stats" => {} }
  end

  # Stands in for `quaacks index-test` over the transport: records each
  # round's DDL and answers with the scripted index_outcome messages.
  let(:rounds) { [] }
  let(:answers) { [] }
  let(:index_test) do
    lambda do |ddls|
      rounds << ddls
      answers.shift or raise "index-test called more often than scripted"
    end
  end

  def accepted(index)
    { "type" => "index_outcome", "index" => index, "outcome" => "accepted", "rule" => nil,
      "covered_by" => nil, "partial_constant_only" => false }
  end

  def dropped(index, rule, covered_by: nil)
    { "type" => "index_outcome", "index" => index, "outcome" => "dropped", "rule" => rule,
      "covered_by" => covered_by, "partial_constant_only" => false }
  end

  def run = described_class.new(client:, index_test:).run(payload)

  def user_texts(ask) = ask.body[:messages].select { it[:role] == :user }.map { it[:content] }

  describe "the first ask" do
    before do
      fake.reply("llm-index-ideas", { "indexes" => ["CREATE INDEX ON public.customers (email text_pattern_ops)"] })
      answers << [accepted(1)]
    end

    it "sends the payload as JSON and asks for up to five indexes as structured output" do
      run
      ask = fake.asks.first

      expect(ask.step).to eq("llm-index-ideas")
      expect(JSON.parse(user_texts(ask).first[/```json\n(.*)\n```/m, 1])).to eq(payload)
      expect(ask.body[:output_config]).to eq(format: { type: :json_schema, schema: described_class::SCHEMA })
      expect(ask.body[:system]).to include("up to five")
    end

    it "says plainly that an unqualified table name gets the candidate refused and counts against it" do
      run

      expect(fake.asks.first.body[:system])
        .to include("Always schema-qualify the table name")
        .and include("an unqualified table name gets the candidate refused, and it counts against you")
    end

    it "says existing and mechanical indexes are already covered, and asks for the kinds they miss" do
      run
      system = fake.asks.first.body[:system]

      expect(system).to include("mechanical_results").and include("already covered")
      %w[Partial Expression BRIN text_pattern_ops trigram low-cardinality].each { expect(system).to include(it) }
    end

    it "tests what the LLM wrote, and stops when nothing is dropped" do
      result = run

      expect(rounds).to eq([["CREATE INDEX ON public.customers (email text_pattern_ops)"]])
      expect(fake.asks.size).to eq(1)
      expect(result.rounds.map(&:outcomes)).to eq([[accepted(1)]])
    end
  end

  describe "the replacement round" do
    let(:first) do
      ["CREATE INDEX ON customers (lower(email))", "CREATE INDEX ON public.customers (email text_pattern_ops)",
       "CREATE INDEX ON public.orders (status)"]
    end

    before do
      fake.reply("llm-index-ideas", { "indexes" => first })
      fake.reply("llm-index-ideas", { "indexes" => ["CREATE INDEX ON public.customers (lower(email))"] })
      answers << [dropped(1, "unqualified_table"), accepted(2),
                  dropped(3, "covered_by_existing", covered_by: "orders_status_created_at_idx")]
      answers << [accepted(1)]
    end

    it "tells the LLM which were dropped and why, and asks for that many replacements" do
      run
      text = user_texts(fake.asks.last).last

      expect(fake.asks.size).to eq(2)
      expect(text).to include("1. `CREATE INDEX ON customers (lower(email))`: its table name isn't schema-qualified")
      expect(text).to include("2. `CREATE INDEX ON public.orders (status)`: " \
                              "already covered by `orders_status_created_at_idx`")
      expect(text).not_to include("text_pattern_ops")
      expect(text).to include("up to 2 replacements")
      expect(fake.asks.last.body[:messages][1]).to eq(role: :assistant, content: JSON.generate("indexes" => first))
    end

    it "tells progress the second ask is for replacements, not a repeat of the first" do
      notes = []
      client.progress = Object.new.tap { |p| p.define_singleton_method(:note) { notes << it } }
      run

      expect(notes).to eq(["Asking the LLM for index ideas (llm-index-ideas)",
                           "Asking the LLM again, for replacements for the dropped ideas (llm-index-ideas)"])
    end

    it "asks for the replacements on the provider that gave the first ideas, as one unit" do
      other = FakeLLM.new
      other.reply("llm-rewrites", { "rewrites" => [] })
      fakes = { "a" => fake, "b" => other }
      router = router_over(fakes)
      described_class.new(client: router, index_test:).run(payload)
      router.ask(step: "llm-rewrites", messages: [{ role: :user, content: "x" }], max_tokens: 10)

      expect(fakes.transform_values { it.asks.map(&:step) })
        .to eq("a" => %w[llm-index-ideas llm-index-ideas], "b" => %w[llm-rewrites])
    end

    it "says which provider answered the unit and which round each was, for the provenance record" do
      result = described_class.new(client: router_over({ "a" => fake, "b" => FakeLLM.new }), index_test:).run(payload)

      expect([result.provider, result.rounds.map(&:round), result.skipped]).to eq(["a", %w[first replacement], nil])
    end

    it "tests the replacements, and asks only once even if more are dropped" do
      answers[1] = [dropped(1, "duplicate")]
      result = run

      expect(rounds).to eq([first, ["CREATE INDEX ON public.customers (lower(email))"]])
      expect(fake.asks.size).to eq(2)
      expect(result.rounds.map(&:ddls)).to eq(rounds)
    end
  end

  # DESIGN.md, "Several LLM providers" (Routing): a replacement round
  # whose ask fails with a rule that fails over is skipped.
  describe "a replacement round that fails" do
    let(:first) { ["CREATE INDEX ON customers (lower(email))", "CREATE INDEX ON public.customers (email)"] }
    let(:other) { FakeLLM.new }
    let(:notes) { [] }
    let(:client) { router_over({ "a" => fake, "b" => other }, routing: { "mode" => "failover" }, max_retries: 0) }

    before do
      seen = notes
      client.progress = Object.new.tap { |p| p.define_singleton_method(:note) { seen << it } }
      fake.reply("llm-index-ideas", { "indexes" => first })
      answers << [dropped(1, "unqualified_table"), accepted(2)]
    end

    it "keeps the first round's ideas, asks no one else, and says it goes on without replacements" do
      fake.error("llm-index-ideas", status: 429)
      result = run

      expect(result.rounds.map(&:ddls)).to eq([first])
      expect([result.provider, result.skipped]).to eq(%w[a llm_rate_limited])
      expect(rounds).to eq([first])
      expect(other.asks).to eq([])
      expect(notes.last).to eq("a is rate limited, so the rest of this run skips it; going on without replacement " \
                               "ideas (llm-index-ideas)")
    end

    it "names the rewrite's step when it searches for a rewrite" do
      fake.reply("rewrite-llm-index-ideas", { "indexes" => first }).cut_short("rewrite-llm-index-ideas", "par")
      described_class.new(client:, index_test:, step: described_class::REWRITE_STEP).run(payload)

      expect(notes.last).to eq("a's reply couldn't be used, though later asks may still use it; going on without " \
                               "replacement ideas (rewrite-llm-index-ideas)")
    end

    it "fails the step on llm_bad_request" do
      fake.error("llm-index-ideas", status: 400)

      expect { run }.to raise_error(Quaack::Driver::LLM::Error, /\Allm_bad_request: a: /)
    end

    context "from an llm block" do
      let(:client) { router_of(fake, max_retries: 0) }

      it "keeps the first round's ideas too" do
        fake.error("llm-index-ideas", status: 503)

        expect(run.rounds.map(&:ddls)).to eq([first])
        expect(notes.last).to eq("The LLM is unavailable, so the rest of this run skips it; going on without " \
                                 "replacement ideas (llm-index-ideas)")
      end
    end
  end

  it "doesn't ask for replacements when every candidate was accepted or set aside" do
    fake.reply("llm-index-ideas", { "indexes" => ["CREATE INDEX ON public.customers USING gin (email gin_trgm_ops)"] })
    answers << [accepted(1).merge("outcome" => "set_aside")]

    expect(run.rounds.size).to eq(1)
    expect(fake.asks.size).to eq(1)
  end

  it "leaves too_many drops out of the replacement ask, and skips it when they're the only drops" do
    ddls = (1..7).map { "CREATE INDEX ON public.customers (c#{it})" }
    fake.reply("llm-index-ideas", { "indexes" => ddls })
    fake.reply("llm-index-ideas", { "indexes" => [] })
    answers << [dropped(1, "duplicate"), *(2..5).map { accepted(it) }, dropped(6, "too_many"), dropped(7, "too_many")]
    run
    text = user_texts(fake.asks.last).last

    expect(text).to include("up to 1 replacements")
    expect(text).not_to include("(c6)")

    fake.reply("llm-index-ideas", { "indexes" => ddls })
    answers << [*(1..5).map { accepted(it) }, dropped(6, "too_many"), dropped(7, "too_many")]
    expect { run }.to change { fake.asks.size }.by(1)
  end

  describe ".index_test" do
    # Stands in for the ssh transport, at the edge: records each call and
    # answers with the enclave's messages.
    let(:transport) do
      Class.new do
        attr_reader :calls

        def initialize(messages)
          @messages = messages
          @calls = []
        end

        def call(subcommand, **options)
          @calls << [subcommand, options]
          Data.define(:messages).new(messages: @messages)
        end
      end.new([accepted(1), { "type" => "other" }])
    end

    it "calls quaacks index-test for the run and search with {\"ddls\": [...]}, and returns its index_outcomes" do
      index_test = described_class.index_test(transport, run_id: "RUN", search: "original")
      ddl = "CREATE INDEX ON public.customers (email)"

      expect(index_test.call([ddl])).to eq([accepted(1)])
      expect(transport.calls)
        .to eq([["index-test", { args: { run: "RUN", search: "original" }, input: { "ddls" => [ddl] } }]])
    end
  end

  it "skips the enclave when the LLM proposes nothing" do
    fake.reply("llm-index-ideas", { "indexes" => [] })

    expect(run.rounds).to eq([])
    expect(rounds).to eq([])
  end
end
