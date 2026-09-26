# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/pipeline"
require_relative "support/fake_llm"

RSpec.describe Quaack::Driver::Pipeline do
  let(:fake) { FakeLLM.new }
  let(:client) { fake.client(burndown: Quaack::Driver::Burndown.new) }
  let(:payload) { { "type" => "index_payload", "query" => "SELECT 1", "mechanical_results" => {} } }
  let(:feedback) { { "type" => "index_feedback", "revise" => false, "refined" => false } }
  let(:entries) do
    { "index_search_original" => false, "index_generated_original" => false, "index_ranking_original" => false }
  end

  # Stands in for the ssh transport, at the edge: records each call and
  # answers with the enclave's messages for that subcommand.
  let(:transport) do
    replies = { "status" => [{ "type" => "status", "entries" => entries }], "index-payload" => [payload],
                "index-feedback" => [feedback],
                "index-test" => [{ "type" => "index_outcome", "index" => 1, "outcome" => "accepted" }] }
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }

      define_method(:call) do |subcommand, **options|
        @calls << [subcommand, options]
        Data.define(:messages).new(messages: replies.fetch(subcommand, []))
      end
    end.new
  end

  def run = described_class.new(transport:, client:, run_id: "RUN").run
  def subcommands = transport.calls.map(&:first)

  it "runs step 5 in the README's order: plan gate and 5a-1 to 5a-4, 5a-5, 5a-6, then 5a-7" do
    fake.reply("5a-5", { "indexes" => ["CREATE INDEX ON public.t (a)"] })

    run

    expect(subcommands).to eq(%w[status index-search index-payload index-test index-feedback index-rank])
    expect(transport.calls.map { it.last[:args] }.uniq).to eq([{ run: "RUN" }, { run: "RUN", search: "original" }])
    expect(fake.asks.map(&:step)).to eq(["5a-5"])
  end

  it "runs the refinement round when the feedback asks for one" do
    fake.reply("5a-5", { "indexes" => ["CREATE INDEX ON public.t (a)"] })
    fake.reply("5a-6", { "indexes" => ["CREATE INDEX ON public.t (b)"] })
    feedback.merge!("revise" => true, "candidates" => [{ "shortfall" => "unused" }], "baseline" => {})

    run

    expect(subcommands).to eq(%w[status index-search index-payload index-test index-feedback index-test index-rank])
    expect(transport.calls[5].last[:args]).to include(round: "refinement")
  end

  it "records 5a-5 as done with an empty index-test when the LLM proposes nothing" do
    fake.reply("5a-5", { "indexes" => [] })

    run

    expect(transport.calls.select { it.first == "index-test" }.map { it.last[:input] }).to eq([{ "ddls" => [] }])
  end

  it "resumes, skipping the steps whose outputs are already in the store" do
    entries.merge!("index_search_original" => true, "index_generated_original" => true)

    run

    expect(subcommands).to eq(%w[status index-payload index-feedback index-rank])
    expect(fake.asks).to eq([])

    entries["index_ranking_original"] = true
    transport.calls.clear
    run
    expect(subcommands).to eq(%w[status index-payload index-feedback])
  end
end
