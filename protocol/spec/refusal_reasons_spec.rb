# frozen_string_literal: true

require "quaack/protocol/refusal_reasons"

# Task 20261110-7: the one list of why a result comparison refused (rule
# unsupported_order), which the enclave sets and stores and the driver words.
RSpec.describe Quaack::Protocol::RefusalReasons do
  def valid?(value) = described_class.valid?(value)

  it "passes each of QUAACK's own reasons" do
    expect(described_class::NAMES.map { valid?(it) }).to all(be(true))
    expect(described_class::NAMES).to all(match(/\A[a-z]+(_[a-z]+)*\z/))
  end

  [
    ["nil", nil],
    ["another word", "order"],
    ["a reason in another case", "Cut_tie"],
    ["a Symbol", :cut_tie],
    ["an Array of a reason", ["cut_tie"]],
    ["a sentinel", "QSENTINEL7741"]
  ].each do |what, value|
    it "refuses #{what}" do
      expect(valid?(value)).to be(false)
    end
  end
end
