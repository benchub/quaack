# frozen_string_literal: true

require "quaack/enclave/rewrite_burndown"

# Why rewrite-test's burndown drops a rewrite (DESIGN.md burndown).
RSpec.describe Quaack::Enclave::RewriteBurndown do
  def drop(scenario, rule) = described_class.test_drop({ "passed" => false, "scenario" => scenario, "rule" => rule })

  it "drops a disproof by its scenario, and a test that compared nothing by its rule" do
    expect(drop("s3", "multiset")).to eq(:s3)
    expect(drop("s1", "query_failed")).to eq(:query_failed)
  end

  # Task 20261012-11: the original failed on every fixture, so nothing was
  # compared. That's untested, by its own rule, not a bare failure.
  it "drops a rewrite compared on no fixture, because the original failed on each, as original_failed" do
    expect(drop(nil, "original_failed")).to eq(:original_failed)
  end

  it "drops anything else as failed" do
    expect(drop(nil, "SENTINEL_DROP_7a")).to eq(:failed)
  end
end
