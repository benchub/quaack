# frozen_string_literal: true

require "quaack/enclave/selection"

RSpec.describe Quaack::Enclave::Selection do
  def s(label, slow, sum, footprint = 0)
    { "label" => label, "slow_blocks" => slow, "total_blocks_sum" => sum, "footprint" => footprint }
  end

  def minimax(survivors, verdicts: {}, ties: [], infinite: [])
    labels = survivors.map { it["label"] } + ties + verdicts.keys
    { "survivors" => survivors, "verdicts" => labels.to_h { [it, {}] }.merge(verdicts),
      "discarded_ties" => ties, "infinite_sets" => infinite }
  end

  # Each discarded rewrite failed with a result mismatch.
  def pick(minimax, discarded = [])
    verdicts = discarded.to_h { [it, { "slow" => { "result" => "fail", "rule" => "multiset" } }] }
    described_class.select(minimax:, result_comparison: { "discarded" => discarded, "verdicts" => verdicts })
  end

  it "keeps all survivors when there are fewer than three" do
    result = pick(minimax([s("rewrite_1:none", 10, 30), s("original:top:1", 5, 20, 100)]))
    expect(result["top"]).to eq([s("original:top:1", 5, 20, 100).merge("kind" => "original_new_indexes"),
                                 s("rewrite_1:none", 10, 30).merge("kind" => "rewrite_same_indexes")])
    expect(result["excluded"]).to eq({})
  end

  it "keeps the top three by slow blocks and excludes the rest as below the top three" do
    result = pick(minimax([s("a:none", 40, 1), s("b:none", 10, 1), s("c:none", 30, 1), s("d:none", 20, 1)]))
    expect(result["top"].map { it["label"] }).to eq(%w[b:none d:none c:none])
    expect(result["excluded"]).to eq("a:none" => "below_top_three")
  end

  it "keeps the top three in each kind of change, each entry carrying its kind, best first overall" do
    survivors = [s("original:top:1", 50, 1), s("original:top:2", 51, 1), s("original:top:3", 52, 1),
                 s("original:combination", 53, 1), s("rewrite_1:top:1", 60, 1), s("rewrite_1:none", 70, 1),
                 s("rewrite_2:none", 71, 1), s("rewrite_3:none", 72, 1), s("rewrite_4:none", 73, 1),
                 s("rewrite_2:top:1", 5, 1), s("rewrite_2:top:2", 6, 1), s("rewrite_2:top:3", 7, 1),
                 s("rewrite_2:combination", 8, 1)]
    result = pick(minimax(survivors))
    kinds = result["top"].group_by { it["kind"] }.transform_values { |entries| entries.map { it["label"] } }
    expect(kinds).to eq("rewrite_new_indexes" => %w[rewrite_2:top:1 rewrite_2:top:2 rewrite_2:top:3],
                        "original_new_indexes" => %w[original:top:1 original:top:2 original:top:3],
                        "rewrite_same_indexes" => %w[rewrite_1:none rewrite_2:none rewrite_3:none])
    expect(result["top"].map { it["slow_blocks"] }).to eq(result["top"].map { it["slow_blocks"] }.sort)
    expect(result["excluded"]).to eq("original:combination" => "below_top_three",
                                     "rewrite_1:top:1" => "below_top_three",
                                     "rewrite_2:combination" => "below_top_three",
                                     "rewrite_4:none" => "below_top_three")
  end

  it "orders the kept entries best first overall even when the kinds interleave" do
    result = pick(minimax([s("rewrite_1:top:1", 5, 1), s("original:top:1", 6, 1), s("rewrite_1:top:2", 7, 1),
                           s("rewrite_1:none", 8, 1)]))
    expect(result["top"].map { it["label"] }).to eq(%w[rewrite_1:top:1 original:top:1 rewrite_1:top:2 rewrite_1:none])
  end

  it "breaks ties in slow blocks by the sum across literals" do
    result = pick(minimax([s("a:none", 10, 50), s("b:none", 10, 20)]))
    expect(result["top"].map { it["label"] }).to eq(%w[b:none a:none])
  end

  it "removes every combination of a rewrite that result-comparison discarded, but not index-only candidates" do
    result = pick(minimax([s("rewrite_1:none", 1, 1), s("rewrite_1:top:1", 2, 2), s("rewrite_10:none", 3, 3),
                           s("original:top:1", 4, 4)]), ["rewrite_1"])
    expect(result["top"].map { it["label"] }).to eq(%w[rewrite_10:none original:top:1])
    expect(result["excluded"]).to eq("rewrite_1:none" => "result_mismatch", "rewrite_1:top:1" => "result_mismatch")
  end

  it "says why result-comparison discarded a rewrite: different results, a timeout, or nothing compared" do
    fail_on = ->(rule) { { "slow" => { "result" => "fail", "rule" => rule } } }
    verdicts = { "rewrite_1" => fail_on.call("multiset"), "rewrite_2" => fail_on.call("timed_out"),
                 "rewrite_3" => fail_on.call("unsupported_order"),
                 "rewrite_4" => { "slow" => { "result" => "fail", "rule" => "timed_out" },
                                  "typical" => { "result" => "fail", "rule" => "row_count" } } }
    survivors = (1..4).map { s("rewrite_#{it}:none", it, it) }
    result = described_class.select(minimax: minimax(survivors),
                                    result_comparison: { "discarded" => %w[rewrite_1 rewrite_2 rewrite_3 rewrite_4],
                                                         "verdicts" => verdicts })
    expect(result["excluded"]).to eq("rewrite_1:none" => "result_mismatch", "rewrite_2:none" => "result_timed_out",
                                     "rewrite_3:none" => "result_not_compared",
                                     "rewrite_4:none" => "result_mismatch")
  end

  it "explains candidates dropped by minimax and by the footprint tiebreaker" do
    result = pick(minimax([s("a:none", 1, 1)], verdicts: { "b:none" => {} }, ties: ["c:none"]))
    expect(result["excluded"]).to eq("b:none" => "not_better", "c:none" => "footprint_tie")
  end

  it "passes on the sets where the original was infinite" do
    result = pick(minimax([s("a:none", 1, 1)], infinite: ["slow"]))
    expect(result["infinite_sets"]).to eq(["slow"])
    expect(result["top"].map { it["label"] }).to eq(["a:none"])
  end
end
