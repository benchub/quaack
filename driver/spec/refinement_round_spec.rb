# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/refinement_round"
require_relative "support/fake_llm"
require_relative "support/routers"

RSpec.describe Quaack::Driver::RefinementRound do
  include Routers

  let(:fake) { FakeLLM.new }
  let(:client) { router_of(fake) }
  let(:payload) { { "query" => "SELECT * FROM public.orders WHERE status = $1", "mechanical_results" => {} } }
  let(:short) do
    { "ddl" => "CREATE INDEX ON public.orders USING btree (created_at) WHERE status = 'held'",
      "plans" => { "slow" => { "used" => false, "total_cost" => 90.0, "plan" => [] } },
      "shortfall" => "unused", "beaten_by" => nil }
  end
  let(:feedback) do
    { "type" => "index_feedback", "revise" => true, "refined" => false, "baseline" => { "slow" => 90.0 },
      "candidates" => [short, short.merge("shortfall" => nil)] }
  end
  let(:tested) { [] }
  let(:index_test) do
    lambda do |ddls, round:|
      tested << [ddls, round]
      [{ "type" => "index_outcome", "index" => 1, "outcome" => "accepted" }]
    end
  end

  def run = described_class.new(client:, index_feedback: -> { feedback }, index_test:).run(payload)

  it "sends the payload and the LLM's own index-test results, and tests its revisions as the refinement round" do
    fake.reply("llm-index-refine",
               { "indexes" => ["CREATE INDEX ON public.orders (created_at) WHERE status <> 'open'"] })

    result = run
    ask = fake.asks.first
    text = ask.body[:messages].map { it[:content] }.join

    expect(ask.step).to eq("llm-index-refine")
    expect(text).to include(JSON.generate(payload)).and include(JSON.generate(feedback["candidates"]))
    expect(text).to include("Propose up to 1 revised")
    expect(ask.body[:system]).to include("revise")
    expect(tested).to eq([[["CREATE INDEX ON public.orders (created_at) WHERE status <> 'open'"], "refinement"]])
    expect(result.outcomes.map { it["outcome"] }).to eq(["accepted"])
  end

  # One unit on one provider, which may not have written every candidate
  # it's shown (DESIGN.md's llm-index-refine).
  it "says an LLM already proposed the candidates, never that this model did" do
    fake.reply("llm-index-refine", { "indexes" => [] })
    run
    ask = fake.asks.first
    sent = [ask.body[:system], *ask.body[:messages].map { it[:content] }].join("\n")

    expect(ask.body[:system]).to include("An LLM already proposed candidates")
    expect(sent).not_to match(/\b(you|your)\b[^.]*\b(proposed|candidates)\b/i)
  end

  it "skips the round when nothing fell short, or when it already ran" do
    base = feedback.dup
    [{ "revise" => false }, { "refined" => true }].each do |change|
      feedback.replace(base.merge(change))
      expect(run).to be_nil
    end
    expect([fake.asks, tested]).to eq([[], []])
  end

  it "records that the round ran, with an empty refinement index-test, when the LLM offers no revision" do
    fake.reply("llm-index-refine", { "indexes" => [] })

    expect(run.ddls).to eq([])
    expect(tested).to eq([[[], "refinement"]])
  end

  it "builds its enclave calls over the transport" do
    transport = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def call(subcommand, **options)
        @calls << [subcommand, options]
        Data.define(:messages).new(messages: [{ "type" => "index_feedback", "revise" => false }, { "type" => "x" }])
      end
    end.new

    expect(described_class.index_feedback(transport, run_id: "RUN", search: "original").call)
      .to eq("type" => "index_feedback", "revise" => false)
    described_class.index_test(transport, run_id: "RUN", search: "original").call(["D"], round: "refinement")
    expect(transport.calls).to eq(
      [["index-feedback", { args: { run: "RUN", search: "original" } }],
       ["index-test", { args: { run: "RUN", search: "original", round: "refinement" }, input: { "ddls" => ["D"] } }]]
    )
  end
end
