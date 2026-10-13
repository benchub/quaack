# frozen_string_literal: true

require "quaack/protocol/vacuity_diagnostic"
require "quaack/protocol/whitelist"

# The one check on what rewrite-test says about why atoms stayed vacuous:
# the rule S1 failed to load with, from a fixed list, and how many rows the
# original returned on S1. Never an error message or a value.
RSpec.describe Quaack::Protocol::VacuityDiagnostic do
  let(:sentinel) { "SENTINEL_VACUITY_5e1c" }

  def valid?(fields) = described_class.valid?(fields)

  it "lists the rules, as frozen Strings" do
    expect(described_class::LOAD_RULES).to include("fixture_load_failed", "statement_timeout")
    expect(described_class::LOAD_RULES).to be_frozen.and(all(be_frozen))
  end

  it "is whitelisted on rewrite_test under the names it checks" do
    expect(Quaack::Protocol::WHITELIST[:rewrite_test].map(&:name))
      .to include("s1_load_rule", "s1_rows", "s1_nonzero_rows")
  end

  it "whitelists rewrite_test's fuzz and enumerate counts, which Protocol::FuzzResult checks (20261012-3)" do
    expect(Quaack::Protocol::WHITELIST[:rewrite_test].map(&:name)).to include("stage", "trials", "worlds", "bound")
  end

  it "takes a rule from the list or nil, and a row count or nil, and ignores other fields" do
    expect(valid?({ "s1_load_rule" => "fixture_load_failed", "s1_rows" => nil, "passed" => true })).to be(true)
    expect(valid?({ "s1_load_rule" => nil, "s1_rows" => 0 })).to be(true)
    expect(valid?({ "s1_rows" => 1, "s1_nonzero_rows" => 0 })).to be(true)
    expect(valid?({ "s1_nonzero_rows" => nil })).to be(true)
    expect(valid?({})).to be(true)
  end

  # Task 20261012-11: S1 loaded, but its rows made the original fail.
  it "takes original_failed, with no row counts" do
    expect(valid?({ "s1_load_rule" => "original_failed", "s1_rows" => nil, "s1_nonzero_rows" => nil })).to be(true)
  end

  it "caps s1_rows at MAX_ROWS, a few million, inclusive" do
    expect(described_class::MAX_ROWS).to eq(2_000_000)
    expect(valid?({ "s1_rows" => described_class::MAX_ROWS })).to be(true)
    expect(valid?({ "s1_rows" => described_class::MAX_ROWS + 1 })).to be(false)
    expect(valid?({ "s1_nonzero_rows" => described_class::MAX_ROWS })).to be(true)
    expect(valid?({ "s1_nonzero_rows" => described_class::MAX_ROWS + 1 })).to be(false)
  end

  it "refuses a rule not on the list, a non-count, and a negative or huge count, never quoting it" do
    [{ "s1_load_rule" => sentinel }, { "s1_load_rule" => 5 }, { "s1_rows" => sentinel }, { "s1_rows" => "3" },
     { "s1_rows" => -1 }, { "s1_rows" => 10**13 }, { "s1_rows" => 10**12 }, { "s1_rows" => 1.5 },
     { "s1_nonzero_rows" => sentinel }, { "s1_nonzero_rows" => "0" }, { "s1_nonzero_rows" => -1 },
     { "s1_nonzero_rows" => true }, { "s1_nonzero_rows" => 0.5 }].each do |fields|
      expect(valid?(fields)).to be(false), fields.inspect
    end
  end
end
