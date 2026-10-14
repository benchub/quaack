# frozen_string_literal: true

require_relative "spec_helper"
require "quaack/enclave/generator_three"
require "quaack/enclave/result_comparator"
require "quaack/driver/report/words"

# Task 20261004-77: the report names why an LLM round dropped an index
# idea by the rule's words. The driver can't load the enclave to read its
# rules, so this cross-gem spec holds the two sides together.
RSpec.describe Quaack::Driver::Report::Words do
  it "has words for every rule the enclave drops an LLM index idea for before deduplicating it" do
    missing = Quaack::Enclave::GeneratorThree::REFUSALS.reject { described_class::COUNTS.key?(it) }

    expect(missing).to eq([])
  end

  # Task 20261012-37: the progress line's search sentence and the report's
  # search disproofs read a mismatch by these words' rules, so they must be
  # the rules the enclave's comparison calls a mismatch.
  it "has words for exactly the rules the enclave's result comparison calls a mismatch" do
    expect(described_class::MISMATCHES.keys.sort)
      .to eq(Quaack::Enclave::ResultComparator::MISMATCHES.map(&:to_s).sort)
  end
end
