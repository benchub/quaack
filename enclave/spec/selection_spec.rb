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

  def pick(minimax, discarded = [])
    described_class.select(minimax:, result_comparison: { "discarded" => discarded })
  end

  it "keeps all survivors when there are fewer than three" do
    result = pick(minimax([s("rewrite_1:none", 10, 30), s("original:top:1", 5, 20, 100)]))
    expect(result["top"]).to eq([s("original:top:1", 5, 20, 100), s("rewrite_1:none", 10, 30)])
    expect(result["excluded"]).to eq({})
  end

  it "keeps the top three by slow blocks and excludes the rest as below the top three" do
    result = pick(minimax([s("a:none", 40, 1), s("b:none", 10, 1), s("c:none", 30, 1), s("d:none", 20, 1)]))
    expect(result["top"].map { it["label"] }).to eq(%w[b:none d:none c:none])
    expect(result["excluded"]).to eq("a:none" => "below_top_three")
  end

  it "breaks ties in slow blocks by the sum across literals" do
    result = pick(minimax([s("a:none", 10, 50), s("b:none", 10, 20)]))
    expect(result["top"].map { it["label"] }).to eq(%w[b:none a:none])
  end

  it "removes every combination of a rewrite that 14c discarded, but not index-only candidates" do
    result = pick(minimax([s("rewrite_1:none", 1, 1), s("rewrite_1:top:1", 2, 2), s("rewrite_10:none", 3, 3),
                           s("original:top:1", 4, 4)]), ["rewrite_1"])
    expect(result["top"].map { it["label"] }).to eq(%w[rewrite_10:none original:top:1])
    expect(result["excluded"]).to eq("rewrite_1:none" => "result_mismatch", "rewrite_1:top:1" => "result_mismatch")
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
