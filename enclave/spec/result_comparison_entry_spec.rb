# frozen_string_literal: true

require "quaack/enclave/steps/result_comparison"

# README 14c: the stored entry counts partial verdicts for the report.
RSpec.describe Quaack::Enclave::Steps::ResultComparison do
  it "counts partial verdicts across candidates and sets, and discards only failures" do
    partial = { "result" => "partial", "rule" => "subset_timed_out" }
    pass = { "result" => "pass", "rule" => nil }
    fail = { "result" => "fail", "rule" => "subset" }
    entry = described_class.entry("rewrite_1" => { "slow" => partial, "typical" => partial },
                                  "rewrite_2" => { "slow" => partial, "typical" => pass },
                                  "rewrite_3" => { "slow" => fail, "typical" => pass })
    expect(entry["partial_count"]).to eq(3)
    expect(entry["discarded"]).to eq(["rewrite_3"])
  end
end
