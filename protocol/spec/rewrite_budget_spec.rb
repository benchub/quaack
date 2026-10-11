# frozen_string_literal: true

require "quaack/protocol/rewrite_budget"

RSpec.describe Quaack::Protocol::RewriteBudget do
  it "is five minutes, with fixed words for the rule and the fate" do
    expect([described_class::SECONDS, described_class.minutes]).to eq([300, 5])
    expect([described_class::RULE, described_class::FATE]).to eq(%w[out_of_time rewrite_test_out_of_time])
  end

  it "accepts nil or a lowercase word as a rewrite_test rule, and nothing else" do
    expect([nil, "out_of_time", "row_count"].map { described_class.rule?(it) }).to all(be(true))
    refused = ["Out of time", "row count", "PG::Error: x", "", :out_of_time, 5, "a" * 64]
    expect(refused.map { described_class.rule?(it) }).to all(be(false))
  end
end
