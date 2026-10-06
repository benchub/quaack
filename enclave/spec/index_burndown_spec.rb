# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/burndown"
require "quaack/enclave/dedupe"
require "quaack/enclave/generator_three"
require "quaack/enclave/index_burndown"
require "quaack/enclave/index_ranking"
require "quaack/enclave/single_candidate_test"
require "quaack/enclave/store"

# IndexBurndown.record_rank's counts, for a ranking that kept a combination, which the step's spec on
# the test harness's data doesn't reach (task 20261001-20).
RSpec.describe Quaack::Enclave::IndexBurndown, ".record_rank" do
  around do |example|
    Dir.mktmpdir("quaack-index-burndown-spec") do |tmp|
      @base = File.join(tmp, "runs")
      example.run
    end
  end

  let(:store) { Quaack::Enclave::Store.create(base: @base) }
  let(:sct) { Quaack::Enclave::SingleCandidateTest }

  def result(used:, refusal: nil)
    plans = refusal ? {} : { slow: sct::Plan.new(used:, total_cost: 1.0, canonical_plan: nil, raw_plan: nil) }
    sct::Result.new(candidate: nil, size: 1, plans:, refusal:)
  end

  it "counts what didn't make the cut: never used, below the top three, and combinations not kept" do
    results = Array.new(5) { result(used: true) } + [result(used: false), result(used: false, refusal: :refused)]
    report = sct::Report.new(baseline: nil, results:)
    tally = Quaack::Enclave::IndexRanking::Tally.new(ranked: 5, combinations: 6, unused_index: 2, explains: 10)
    ranking = Quaack::Enclave::IndexRanking::Ranking.new(top: %i[a b c], combination: :pair, tally:)

    described_class.record_rank(store, :rewrite, {}, [report, ranking])

    burndown = Quaack::Enclave::Burndown.read(store)
    expect(burndown["stages"]).to eq(
      "index-rank" => { "rewrite" => {
        "in" => 7, "added" => { "combinations" => 6 },
        "dropped" => { "never_used" => 1, "hypopg_refused" => 1, "below_top_three" => 2,
                       "combination_unused_index" => 2, "combination_not_chosen" => 3 },
        "set_aside" => 0, "out" => 4, "extra" => {}
      } }
    )
    expect(burndown["totals"]).to eq("hypothetical_explains" => 5 + 1 + 10)
  end

  # Task 20261004-77: index-rank records why llm-index-refine didn't run.
  # If the round runs after all, its record replaces that one.
  describe "an llm-index-refine round after index-rank" do
    let(:entry) { { "results" => [], "llm_results" => [] } }
    let(:report) { sct::Report.new(baseline: nil, results: []) }
    let(:dedupe) do
      orders = Quaack::Enclave::TableName.new(schema: "public", name: "orders")
      table = Quaack::Enclave::TableStatistics.new(name: orders, reltuples: 1, columns: {}, column_names: ["id"],
                                                   indexes: {})
      Quaack::Enclave::Dedupe.new(statistics: Quaack::Enclave::Statistics.new(tables: [table]), low_cardinality: [])
    end

    def refine
      outcome = Quaack::Enclave::GeneratorThree::Outcome.new(index: 1, status: :dropped, rule: "unqualified_table",
                                                             covered_by: nil, partial_constant_only: false,
                                                             candidate: nil)
      result = Quaack::Enclave::GeneratorThree::Result.new(outcomes: [outcome], survivors: [])
      since = Quaack::Enclave::Burndown.dedupe_counts(dedupe)
      described_class.record_round(store, :rewrite, "refinement", entry:, tested: [since, dedupe, result, report])
    end

    def refined = Quaack::Enclave::Burndown.read(store).dig("stages", "llm-index-refine", "rewrite")

    it "replaces the record that said it didn't run, and adds to its own" do
      store.write("index_generated_rewrite", true)
      tally = Quaack::Enclave::IndexRanking::Tally.new(ranked: 0, combinations: 0, unused_index: 0, explains: 0)
      ranking = Quaack::Enclave::IndexRanking::Ranking.new(top: [], combination: nil, tally:)
      described_class.record_rank(store, :rewrite, entry, [report, ranking])
      expect(refined["extra"]).to eq("no_ideas_tested" => 1)

      refine
      expect(refined).to eq("in" => 0, "added" => { "llm" => 1 }, "dropped" => { "unqualified_table" => 1 },
                            "set_aside" => 0, "out" => 0, "extra" => { "fell_short" => 0 })

      refine
      expect(refined).to eq("in" => 0, "added" => { "llm" => 2 }, "dropped" => { "unqualified_table" => 2 },
                            "set_aside" => 0, "out" => 0, "extra" => { "fell_short" => 0 })
    end

    it "replaces a record that said none of the LLM's ideas fell short too" do
      Quaack::Enclave::Burndown.record_replacing(
        store, [["llm-index-refine", :rewrite, { in: 0, out: 0, extra: { nothing_fell_short: 1 } }]]
      )

      refine
      expect(refined["extra"]).to eq("fell_short" => 0)
    end
  end
end
