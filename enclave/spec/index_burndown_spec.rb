# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/burndown"
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
end
