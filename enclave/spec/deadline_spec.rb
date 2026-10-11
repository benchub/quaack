# frozen_string_literal: true

require "quaack/enclave/deadline"

# rewrite-test's wall-clock budget per rewrite (task 20261010-53).
RSpec.describe Quaack::Enclave::Deadline do
  let(:now) { [100.0] }
  let(:clock) { -> { now.first } }

  it "is five minutes by default, the protocol's budget" do
    expect(described_class::SECONDS).to eq(300)
    expect(Quaack::Protocol::RewriteBudget::SECONDS).to eq(300)
  end

  it "passes a check before the budget runs out and raises Expired once it has" do
    deadline = described_class.new(5, clock:)
    now[0] = 104.9
    expect { deadline.check! }.not_to raise_error
    now[0] = 105.0
    expect { deadline.check! }.to raise_error(described_class::Expired)
  end

  it "checks the deadline set for the block, and none outside it" do
    deadline = described_class.new(1, clock:)
    now[0] = 200.0
    expect { described_class.within(deadline) { described_class.check! } }.to raise_error(described_class::Expired)
    expect { described_class.check! }.not_to raise_error
  end
end
