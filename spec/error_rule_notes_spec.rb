# frozen_string_literal: true

require_relative "spec_helper"
require "quaack/protocol/error_rules"
require "quaack/driver/fixed_notes"

# Task 20261007-29: the driver has words for every rule an enclave error
# line can carry. The enclave spec error_rules_spec.rb checks
# Protocol::ErrorRules against the enclave's source; this one holds the
# driver's table to that list, so a new rule can't reach an operator bare.
RSpec.describe Quaack::Driver::FixedNotes do
  let(:names) { Quaack::Protocol::ErrorRules::NAMES }
  let(:given) { [*described_class::BY_RULE.keys, *described_class::INTERNAL, *described_class::CODED] }

  it "gives every rule the enclave can send its own words, the shared internal line, or a note of its own" do
    expect(names - given).to eq([])
  end

  it "gives words only to rules the enclave can send" do
    expect(given.reject { Quaack::Protocol::ErrorRules.known?(it) }).to eq([])
  end

  it "puts each rule in only one of the three" do
    expect(given.tally.select { |_, count| count > 1 }.keys).to eq([])
  end

  it "gives the missing_<entry> family the store's words" do
    expect(described_class.for("missing_inventory",
                               "resume")).to eq(described_class::MISSING_ENTRY.sub("{next}", "resume").chomp("."))
  end
end
