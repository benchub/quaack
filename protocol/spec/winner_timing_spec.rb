# frozen_string_literal: true

require "quaack/protocol/winner_timing"

# Task 20261016-14: the one check on the report's winner_timing, for the
# enclave's egress function and the driver both: how the winner's one timed
# EXPLAIN ANALYZE went, as one of QUAACK's own words, or nil.
RSpec.describe Quaack::Protocol::WinnerTiming do
  def valid?(value) = described_class.valid?(value)

  it "passes nil and each of QUAACK's own words" do
    expect([nil, "timed", "timed_out", "failed", "plan_differs"].map { valid?(it) }).to all(be(true))
  end

  [
    ["another word", "slow"],
    ["a word in another case", "Timed"],
    ["a word with a space", "timed "],
    ["a Symbol", :timed],
    ["a number", 1],
    ["an Array of a word", ["timed"]],
    ["a sentinel", "QSENTINEL7741"]
  ].each do |what, value|
    it "refuses #{what}" do
      expect(valid?(value)).to be(false)
    end
  end
end
