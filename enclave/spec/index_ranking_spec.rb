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
