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

# README 5a-7: an addition must lower some literal set's cost and raise none.
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
