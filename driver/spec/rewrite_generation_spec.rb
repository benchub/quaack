# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/rewrite_generation"
require_relative "support/fake_llm"
require_relative "support/routers"

RSpec.describe Quaack::Driver::RewriteGeneration do
  include Routers

  let(:fake) { FakeLLM.new }
  let(:client) { router_of(fake) }
  let(:payload) do
    { "query" => "SELECT * FROM public.orders WHERE id IN (SELECT order_id FROM public.items WHERE sku = $1)",
      "placeholders" => {}, "plan" => [], "schema" => {}, "stats" => {} }
  end
  let(:rewrite) do
    { "sql" => "SELECT DISTINCT o.* FROM public.orders o JOIN public.items i ON i.order_id = o.id WHERE i.sku = $1",
      "transformation" => "IN subquery to join",
      "assumptions" => [{ "kind" => "unique", "table" => "public.orders", "columns" => ["id"] }] }
  end
  let(:sent) { [] }
  let(:outcome) { { "type" => "rewrite_outcome", "index" => 1, "outcome" => "accepted", "rule" => nil } }
  let(:rewrite_check) { ->(rewrites) { (sent << rewrites) && [outcome] } }

  def run = described_class.new(client:, rewrite_check:).run(payload)

  before { fake.reply("llm-rewrites", { "rewrites" => [rewrite] }) }

  it "sends the payload and asks for up to five rewrites with structured assumptions" do
    run
    ask = fake.asks.first

    expect(ask.step).to eq("llm-rewrites")
    expect(JSON.parse(ask.body[:messages].first[:content][/```json\n(.*)\n```/m, 1])).to eq(payload)
    expect(ask.body[:output_config]).to eq(format: { type: :json_schema, schema: described_class::SCHEMA })
    expect(ask.body[:system]).to include("up to five")
    expect(described_class::SCHEMA.dig(:properties, :rewrites, :maxItems)).to eq(5)
  end

  # Task 20261001-28: DESIGN.md's llm-rewrites, as llm-index-ideas does with mechanical_results.
  it "sends the rule-made rewrites in the payload and says not to repeat them" do
    payload["rule_rewrites"] = [{ "sql" => "SELECT 1", "rules" => ["key_in_self_join"] }]

    run
    ask = fake.asks.first

    expect(JSON.parse(ask.body[:messages].first[:content][/```json\n(.*)\n```/m, 1])["rule_rewrites"])
      .to eq(payload["rule_rewrites"])
    expect(ask.body[:system]).to include("rule_rewrites are the rewrites QUAACK's own rules already made")
      .and include("don't repeat them")
  end

  it "has the enclave check the LLM's rewrites as they are, and returns them with the outcomes" do
    result = run

    expect(sent).to eq([[rewrite]])
    expect(result).to eq(described_class::Result.new(rewrites: [rewrite], outcomes: [outcome],
                                                     entries: ["anthropic"], providers: ["anthropic"]))
  end

  it "says which provider wrote the rewrites, for the provenance record" do
    other = FakeLLM.new.reply("llm-rewrites", { "rewrites" => [] })
    router = router_over({ "a" => FakeLLM.new, "b" => other }, routing: { "steps" => { "llm-rewrites" =>
                                                                                       { "providers" => ["b"] } } })

    expect(described_class.new(client: router, rewrite_check:).run(payload).providers).to eq(["b"])
  end

  it "records that llm-rewrites ran, with an empty rewrite-check, when the LLM proposes nothing" do
    fake = FakeLLM.new
    fake.reply("llm-rewrites", { "rewrites" => [] })

    described_class.new(client: router_of(fake), rewrite_check:).run(payload)

    expect(sent).to eq([[]])
  end

  # DESIGN.md, "Several LLM providers" (Routing, Limits): a fan-out step
  # asks every healthy provider and sends the union in one interleaved
  # rewrite-check call, exact repeats dropped, so the cap stays five in all.
  describe "fan-out" do
    let(:fakes) { %w[a b c].to_h { [it, FakeLLM.new] } }
    let(:notes) { [] }
    let(:client) do
      router_over(fakes, routing: { "steps" => { "llm-rewrites" => { "fan_out" => true } } }, max_retries: 0).tap do |r|
        seen = notes
        r.progress = Object.new.tap { |p| p.define_singleton_method(:note) { seen << it } }
      end
    end
    let(:rewrite_check) do
      lambda do |rewrites|
        sent << rewrites
        rewrites.each_index.map { { "type" => "rewrite_outcome", "index" => it + 1, "outcome" => "accepted" } }
      end
    end

    def written(sql) = { "sql" => sql, "transformation" => "t", "assumptions" => [] }

    it "interleaves each branch's rewrites into one rewrite-check call, dropping exact repeats of the SQL" do
      fakes["a"].reply("llm-rewrites", { "rewrites" => [written("A1"), written("A2"), written("A3")] })
      fakes["b"].reply("llm-rewrites", { "rewrites" => [written("A1"), written("B2")] })
      fakes["c"].reply("llm-rewrites", { "rewrites" => [written("C1"), written("A2"), written("C3"), written("C4")] })

      result = run

      expect(sent.map { |call| call.map { it["sql"] } }).to eq([%w[A1 C1 A2 B2 A3 C3 C4]])
      expect(result.rewrites).to eq(sent.first)
      expect(result.entries).to eq(%w[a c a b a c c])
      expect(result.providers).to eq(%w[a b c])
      expect(result.outcomes.size).to eq(7)
    end

    it "drops a branch that fails and goes on with the others" do
      fakes["a"].error("llm-rewrites", status: 503)
      fakes["b"].reply("llm-rewrites", { "rewrites" => [written("B1")] })
      fakes["c"].reply("llm-rewrites", { "rewrites" => [written("C1")] })

      result = run

      expect([result.entries, result.providers]).to eq([%w[b c], %w[b c]])
      expect(sent.map { |call| call.map { it["sql"] } }).to eq([%w[B1 C1]])
      expect(notes).to include("a failed with llm_unavailable; going on with the others (llm-rewrites)")
    end

    it "still has the enclave record that the step ran when no branch proposed anything" do
      fakes.each_value { it.reply("llm-rewrites", { "rewrites" => [] }) }

      expect(run.providers).to eq(%w[a b c])
      expect(sent).to eq([[]])
    end

    it "fails the step when every branch failed, and checks nothing" do
      fakes.each_value { it.error("llm-rewrites", status: 503) }

      expect { run }.to raise_error(Quaack::Driver::LLM::Error, /every LLM provider llm-rewrites may use failed/)
      expect(sent).to eq([])
    end
  end

  it "builds rewrite_check over the transport as `quaacks rewrite-check --run`" do
    calls = []
    transport = Object.new
    transport.define_singleton_method(:call) do |name, **kw|
      calls << [name, kw]
      Struct.new(:messages).new([{ "type" => "rewrite_outcome", "index" => 1 }, { "type" => "done" }])
    end

    outcomes = described_class.rewrite_check(transport, run_id: "R").call([rewrite])

    expect(calls).to eq([["rewrite-check", { args: { run: "R" }, input: { "rewrites" => [rewrite] } }]])
    expect(outcomes).to eq([{ "type" => "rewrite_outcome", "index" => 1 }])
  end
end
