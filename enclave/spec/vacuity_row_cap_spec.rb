# frozen_string_literal: true

require "quaack/enclave/cli/input"
require "quaack/protocol/vacuity_diagnostic"

# 20261009-46: the cap on s1_rows is the most the enclave reads of anything
# from one input, so the two numbers can't drift apart unseen.
RSpec.describe Quaack::Protocol::VacuityDiagnostic do
  it "caps s1_rows at the most elements the enclave reads from an input" do
    expect(described_class::MAX_ROWS).to eq(Quaack::Enclave::CLI::Input::MAX_ELEMENTS)
  end
end
