# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/rewrite_generation"
require_relative "support/fake_llm"

RSpec.describe Quaack::Driver::RewriteGeneration do
  let(:fake) { FakeLLM.new }
  let(:client) { fake.client(burndown: Quaack::Driver::Burndown.new) }
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
    expect(result).to eq(described_class::Result.new(rewrites: [rewrite], outcomes: [outcome]))
  end

  it "records that llm-rewrites ran, with an empty rewrite-check, when the LLM proposes nothing" do
    fake = FakeLLM.new
    fake.reply("llm-rewrites", { "rewrites" => [] })

    described_class.new(client: fake.client(burndown: Quaack::Driver::Burndown.new), rewrite_check:).run(payload)

    expect(sent).to eq([[]])
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
