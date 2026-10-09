# frozen_string_literal: true

require "quaack/enclave/steps/measured_labels"

# DESIGN.md's report: every reason selection can give goes out as itself.
RSpec.describe Quaack::Enclave::Steps::MeasuredLabels do
  it "sends every Selection reason through excluded" do
    stored = Quaack::Enclave::Selection::REASONS.each_with_index.to_h { |reason, i| ["rewrite_#{i + 1}:none", reason] }
    expect(described_class.excluded(stored).values).to eq(
      %w[result_mismatch result_timed_out result_not_compared below_top_three footprint_tie not_better]
    )
  end

  it "sends an unknown reason as nil" do
    expect(described_class.excluded("rewrite_1:none" => "secret")).to eq("rewrite_1:none" => nil)
  end
end
