# frozen_string_literal: true

require "quaack/enclave/minimax"

# DESIGN.md's blocks-metric and minimax: total blocks, a 5% threshold, minimax, footprint ties.
RSpec.describe Quaack::Enclave::Minimax do
  def m(blocks) = { "timed_out" => false, "total_blocks" => blocks }
  def sets(slow, worst = 100, typical = 100) = { "slow" => m(slow), "worst_case" => m(worst), "typical" => m(typical) }

  let(:original) { sets(100) }

  describe ".verdict" do
    it "calls more than 5% fewer blocks better, exactly 5% fewer no worse" do
      expect(described_class.verdict(94, 100)).to eq("better")
      expect(described_class.verdict(95, 100)).to eq("no_worse")
    end

    it "calls an increase within 5% no worse and beyond it worse" do
      expect(described_class.verdict(105, 100)).to eq("no_worse")
      expect(described_class.verdict(106, 100)).to eq("worse")
    end

    it "treats a timed-out original as infinite, so any finishing count is better" do
      expect(described_class.verdict(10**12, nil)).to eq("better")
    end
  end

  def candidate(label, slow, footprint: 0, worst: 100, typical: 100)
    { "label" => label, "sets" => sets(slow, worst, typical), "footprint" => footprint }
  end

  it "keeps a candidate that beats the slow literal and is no worse elsewhere, and records verdicts" do
    out = described_class.decide(original:, candidates: [candidate("a", 50, worst: 105, typical: 90)])
    expect(out["survivors"].map { it["label"] }).to eq(["a"])
    expect(out["verdicts"]["a"]).to eq("slow" => "better", "worst_case" => "no_worse", "typical" => "better")
  end

  it "drops a candidate that is worse on any other literal, or not better on the slow one" do
    out = described_class.decide(original:, candidates: [candidate("worse", 50, typical: 106),
                                                         candidate("flat", 95)])
    expect(out["survivors"]).to eq([])
    expect(out["verdicts"]["worse"]["typical"]).to eq("worse")
    expect(out["verdicts"]["flat"]["slow"]).to eq("no_worse")
  end

  it "uses the stored max for an unstable literal" do
    unstable = { "timed_out" => false, "stable" => false, "total_blocks" => 120,
                 "runs" => [{ "total_blocks" => 50 }, { "total_blocks" => 120 }, { "total_blocks" => 60 }] }
    c = { "label" => "u", "footprint" => 0, "sets" => sets(50).merge("typical" => unstable) }
    expect(described_class.decide(original:, candidates: [c])["survivors"]).to eq([])
  end

  it "discards the larger footprint among candidates within 5% on the slow literal, ranking the rest" do
    out = described_class.decide(original:, candidates: [candidate("big", 50, footprint: 900),
                                                         candidate("small", 52, footprint: 100),
                                                         candidate("far", 40, footprint: 5000)])
    expect(out["survivors"].map { it["label"] }).to eq(%w[far small])
    expect(out["discarded_ties"]).to eq(["big"])
  end

  it "ties candidates exactly 5% apart on the slow literal" do
    out = described_class.decide(original: sets(200), candidates: [candidate("a", 100, footprint: 900),
                                                                   candidate("b", 105, footprint: 100)])
    expect(out["survivors"].map { it["label"] }).to eq(["b"])
  end

  it "resolves chained ties greedily by footprint, so a discarded candidate knocks out nobody" do
    out = described_class.decide(original: sets(200), candidates: [candidate("a", 100, footprint: 10),
                                                                   candidate("b", 104, footprint: 5),
                                                                   candidate("c", 108, footprint: 1)])
    expect(out["survivors"].map { it["label"] }).to eq(%w[a c])
    expect(out["discarded_ties"]).to eq(["b"])
  end

  it "skips a candidate with a timed-out measurement" do
    c = { "label" => "t", "footprint" => 0, "sets" => sets(50).merge("typical" => { "timed_out" => true }) }
    out = described_class.decide(original:, candidates: [c, candidate("ok", 50)])
    expect(out["survivors"].map { it["label"] }).to eq(["ok"])
    expect(out["verdicts"]).not_to have_key("t")
  end

  it "does not tie candidates more than 5% apart" do
    out = described_class.decide(original:, candidates: [candidate("a", 50, footprint: 900),
                                                         candidate("b", 53, footprint: 100)])
    expect(out["survivors"].map { it["label"] }).to eq(%w[a b])
  end

  it "keeps the smaller sum across literals when footprint and slow blocks are equal" do
    out = described_class.decide(original:, candidates: [candidate("a", 50, typical: 100),
                                                         candidate("b", 50, typical: 90)])
    expect(out["survivors"].map { it["label"] }).to eq(%w[b])
    expect(out["survivors"].first).to include("slow_blocks" => 50, "total_blocks_sum" => 240, "footprint" => 0)
  end

  it "flags sets where the original timed out, and any finishing candidate beats it there" do
    timed = original.merge("worst_case" => { "timed_out" => true })
    out = described_class.decide(original: timed, candidates: [candidate("a", 50, worst: 10**9)])
    expect(out["infinite_sets"]).to eq(["worst_case"])
    expect(out["verdicts"]["a"]["worst_case"]).to eq("better")
    expect(out["survivors"].map { it["label"] }).to eq(["a"])
  end
end
