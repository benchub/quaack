# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/counterexamples"
require_relative "support/fake_llm"
require_relative "support/routers"

# llm-counterexamples, the driver's half: ask the LLM for shape-level inserts that should
# make a candidate and the original disagree.
RSpec.describe Quaack::Driver::Counterexamples do
  include Routers

  let(:fake) { FakeLLM.new }
  let(:client) { router_of(fake) }
  let(:payload) do
    { "original" => "SELECT o.id FROM public.orders o WHERE o.status = $1",
      "candidate" => { "sql" => "SELECT o.id FROM public.orders o WHERE lower(o.status) = $1",
                       "transformation" => "lowercases status", "assumptions" => ["status is lowercase"] },
      "placeholders" => { "$1" => "text" }, "schema" => "CREATE TABLE public.orders (id integer, status text)",
      "constraints" => ["orders_pkey PRIMARY KEY (id)"], "untested_atoms" => ["o.status = $1"] }
  end
  let(:insert) { "INSERT INTO public.orders (id, status) VALUES (1, upper($1))" }

  def user_texts(ask) = ask.body[:messages].select { it[:role] == :user }.map { it[:content] }

  it "sends the payload and returns the LLM's inserts" do
    fake.reply("llm-counterexamples", { "inserts" => [insert] })
    expect(described_class.new(client:).ask(payload)).to eq([insert])
    ask = fake.asks.first
    expect(JSON.parse(user_texts(ask).first[/```json\n(.*)\n```/m, 1])).to eq(payload)
    expect(ask.body[:output_config]).to eq(format: { type: :json_schema, schema: described_class::SCHEMA })
  end

  it "tells the LLM to use $n for the query's literals, to aim at untested atoms, and to satisfy every constraint" do
    fake.reply("llm-counterexamples", { "inserts" => [] })
    described_class.new(client:).ask(payload)
    system = fake.asks.first.body[:system]
    expect(system).to include("$1", "untested_atoms", "every constraint", "schema-qualif")
  end

  it "tells the LLM it may set an identity key with OVERRIDING SYSTEM VALUE (task 20260927-24)" do
    fake.reply("llm-counterexamples", { "inserts" => [] })
    described_class.new(client:).ask(payload)
    system = fake.asks.first.body[:system]
    expect(system).to include("OVERRIDING SYSTEM VALUE")
    expect(system).not_to include("RETURNING, or OVERRIDING")
  end

  it "tells the LLM to write fixed dates and times, not the clock (task 20261004-95)" do
    fake.reply("llm-counterexamples", { "inserts" => [] })
    described_class.new(client:).ask(payload)
    system = fake.asks.first.body[:system]
    expect(system).to include("now()", "CURRENT_DATE", "'now', 'today', 'tomorrow', or 'yesterday'",
                              "fixed dates and times")
  end

  describe "the rounds" do
    let(:outcomes) { [] }
    let(:compared) { [] }
    let(:compare) do
      lambda do |inserts|
        compared << inserts
        outcomes.shift or raise "compare called more often than scripted"
      end
    end

    def clean(covered: [], refused: []) = { "match" => true, "rule" => nil, "covered" => covered, "refused" => refused }

    def run = described_class.new(client:).run(payload, compare:)

    it "runs all three rounds when none finds a mismatch, telling the LLM how each went" do
      3.times { |i| fake.reply("llm-counterexamples", { "inserts" => ["INSERT #{i}"] }) }
      outcomes.push(clean(refused: [{ "index" => 0, "rule" => "insert_select" }]),
                    clean(covered: ["o.status = $1"]), clean)
      result = run
      expect(compared).to eq([["INSERT 0"], ["INSERT 1"], ["INSERT 2"]])
      expect(result.disproved).to be(false)
      expect(result.covered).to eq(["o.status = $1"])
      second = fake.asks[1].body[:messages]
      expect(second.map { it[:role] }).to eq(%i[user assistant user])
      expect(second[1][:content]).to include("INSERT 0")
      expect(second[2][:content]).to include("insert_select", "same results")
    end

    it "tells progress what each round's ask is for" do
      notes = []
      client.progress = Object.new.tap { |p| p.define_singleton_method(:note) { notes << it } }
      3.times { |i| fake.reply("llm-counterexamples", { "inserts" => ["INSERT #{i}"] }) }
      outcomes.push(clean, clean, clean)
      run

      expect(notes).to eq(["Asking the LLM for rows that could break the rewrite (llm-counterexamples)",
                           "Asking the LLM again, for different rows (llm-counterexamples)",
                           "Asking the LLM again, for different rows (llm-counterexamples)"])
    end

    it "keeps a rewrite's rounds on one provider, as one unit, and starts the next rewrite's on the next" do
      other = FakeLLM.new
      3.times { |i| fake.reply("llm-counterexamples", { "inserts" => ["INSERT #{i}"] }) }
      other.reply("llm-counterexamples", { "inserts" => ["INSERT b"] })
      outcomes.push(clean, clean, clean, { "match" => false, "rule" => "multiset", "covered" => [], "refused" => [] })
      router = router_over({ "a" => fake, "b" => other })
      2.times { described_class.new(client: router).run(payload, compare:) }

      expect([fake.asks.size, other.asks.size]).to eq([3, 1])
    end

    it "stops once a round disproves the candidate" do
      2.times { |i| fake.reply("llm-counterexamples", { "inserts" => ["INSERT #{i}"] }) }
      outcomes.push(clean, { "match" => false, "rule" => "multiset", "covered" => [], "refused" => [] })
      result = run
      expect(result.rounds.size).to eq(2)
      expect(result.disproved).to be(true)
    end
    it "keeps going after a round whose inserts failed to load, without calling it disproved" do
      3.times { |i| fake.reply("llm-counterexamples", { "inserts" => ["INSERT #{i}"] }) }
      failed = { "match" => nil, "load_failed" => true, "rule" => "insert_failed", "covered" => [], "refused" => [] }
      outcomes.push(failed, clean, clean)
      result = run
      expect(result.rounds.size).to eq(3)
      expect(result.disproved).to be(false)
      expect(fake.asks[1].body[:messages][2][:content]).to include("failed to load (insert_failed)")
    end
  end
end
