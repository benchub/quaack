# frozen_string_literal: true

require "quaack/enclave/index_ranking"

RSpec.describe Quaack::Enclave::IndexRanking::Cost do
  it "reduces by the fraction of the baseline's cost that the index saves" do
    expect(described_class.new(before: 200.0, after: 50.0).reduction).to eq(0.75)
    expect(described_class.new(before: 8.0, after: 6.0).reduction).to eq(0.25)
  end

  it "goes negative when the index makes the literal worse" do
    expect(described_class.new(before: 10.0, after: 20.0).reduction).to eq(-1.0)
  end

  it "counts the same cost before and after, even zero, as no reduction" do
    expect(described_class.new(before: 0.0, after: 0.0).reduction).to eq(0.0)
    expect(described_class.new(before: 12.5, after: 12.5).reduction).to eq(0.0)
  end
end

# DESIGN.md's index-rank: an addition must lower some literal set's cost and raise none.
RSpec.describe Quaack::Enclave::IndexRanking, ".lower?" do
  def entry(**afters)
    costs = afters.transform_values { |after| Quaack::Enclave::IndexRanking::Cost.new(before: 100.0, after:) }
    Quaack::Enclave::IndexRanking::Entry.new(candidates: [], ddl: [], size: 0, costs:, used: {},
                                             canonical_plans: {}, plans: {}, partial: false)
  end

  let(:current) { entry(slow: 40.0, worst: 90.0) }

  it "accepts one that lowers one set and leaves the rest the same" do
    expect(described_class.lower?(entry(slow: 10.0, worst: 90.0), current)).to be(true)
  end

  it "refuses one that lowers no set" do
    expect(described_class.lower?(entry(slow: 40.0, worst: 90.0), current)).to be(false)
  end

  it "refuses one that makes any set worse, even while it lowers another" do
    expect(described_class.lower?(entry(slow: 10.0, worst: 91.0), current)).to be(false)
  end
end

# 20261004-92: DESIGN.md's index-rank refuses a baseline or result measured with other literal
# values. These run the real check on recorded sets, with no database.
RSpec.describe Quaack::Enclave::IndexRanking, ".check" do
  let(:recorded) { Quaack::Enclave::RecordedLiteralSets }
  let(:mismatch) { [ArgumentError, "literal sets must match the baseline's and every result's"] }

  def baseline_for(sets)
    Quaack::Enclave::SingleCandidateTest::Baseline.new(plans: sets.transform_values { nil },
                                                       literal_sets: Quaack::Enclave::RecordedLiteralSets.copy(sets))
  end

  def check(sets, baseline) = described_class.send(:check, sets, baseline, [])

  it "accepts the same values" do
    sets = { slow: ["a", nil], typical: ["b"] }

    expect(check({ slow: ["a", nil], typical: ["b"] }, baseline_for(sets))).to be_nil
  end

  it "keeps its own copy, so editing a caller's string in place can't make a changed value match" do
    sets = { slow: [+"open"] }
    baseline = baseline_for(sets)
    sets[:slow][0] << "ed"

    expect(baseline.literal_sets).to eq(slow: ["open"])
    expect(baseline.literal_sets[:slow][0]).to be_frozen
    expect { check(sets, baseline) }.to raise_error(*mismatch)
  end

  it "keeps a nil value nil" do
    expect(recorded.copy({ slow: [nil, +"a"] })).to eq(slow: [nil, "a"])
  end

  it "treats a set's values as positional, so the same values in another order are refused" do
    baseline = baseline_for({ slow: %w[a b], typical: %w[c d] })

    expect { check({ slow: %w[b a], typical: %w[c d] }, baseline) }.to raise_error(*mismatch)
    expect { check({ slow: %w[a b], typical: %w[d c] }, baseline) }.to raise_error(*mismatch)
  end
end
