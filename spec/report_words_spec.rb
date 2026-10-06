# frozen_string_literal: true

require_relative "spec_helper"
require "quaack/enclave/generator_three"
require "quaack/driver/report/words"

# Task 20261004-77: the report names why an LLM round dropped an index
# idea by the rule's words. The driver can't load the enclave to read its
# rules, so this cross-gem spec holds the two sides together.
RSpec.describe Quaack::Driver::Report::Words do
  it "has words for every rule the enclave drops an LLM index idea for before deduplicating it" do
    missing = Quaack::Enclave::GeneratorThree::REFUSALS.reject { described_class::COUNTS.key?(it) }

    expect(missing).to eq([])
  end
end
