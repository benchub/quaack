# frozen_string_literal: true

require "quaack/protocol/parser_major"
require "quaack/protocol/whitelist"

# The parser major a query_unparsable error line carries (20261009-2), which
# the enclave sends and the driver checks again.
RSpec.describe Quaack::Protocol::ParserMajor do
  it "goes only on query_unparsable" do
    expect(described_class::RULE).to eq("query_unparsable")
  end

  it "is an error-line field on the whitelist" do
    expect(Quaack::Protocol::WHITELIST.fetch(:error)).to include(:parser_major)
  end

  it "keeps a plain Integer major from 10 to 99" do
    expect([10, 17, 18, 99].map { described_class.check(it) }).to eq([10, 17, 18, 99])
  end

  [
    ["a sentinel String", "SENTINEL-8c21-customers.email"],
    ["a numeric String", "17"],
    ["a Float", 17.0],
    ["a major below 10", 9],
    ["a major above 99", 100],
    ["a big Integer", 10**30],
    ["true", true],
    ["nil", nil],
    ["an Array", [17]]
  ].each do |label, bad|
    it "drops #{label}" do
      expect(described_class.check(bad)).to be_nil
    end
  end
end
