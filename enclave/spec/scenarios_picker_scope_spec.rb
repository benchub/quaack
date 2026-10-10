# frozen_string_literal: true

require "quaack/enclave/scenarios"

# A near miss's pick across scopes (20261010-19): the same test on one
# column in two scopes. The pools, probes, and CHECKs are the inputs, made
# here; the Picker is real.
RSpec.describe Quaack::Enclave::Scenarios::Picker do
  pool = Struct.new(:satisfying, :failing, :boundaries)
  checks_class = Class.new do
    def values(*) = []
    def allows?(*) = true
  end
  let(:checks) { checks_class.new }

  # Two atoms, both state <> 'deleted'.
  let(:pools) { [0, 1].to_h { [it, pool.new(%w[open], %w[deleted], [])] } }
  let(:probes) { [0, 1].to_h { [it, ->(v) { v == "deleted" ? "f" : "t" }] } }

  def picker(scopes) = described_class.new(pools, probes, checks, {}, scopes)

  it "fails a copy of the test in another scope along with the near miss's own" do
    expect(picker({ 0 => [:outer], 1 => [:inner] }).pick([0, 1], [], [0], :plain)).to eq("deleted")
  end

  it "has no value when the copy is in the near miss's own scope" do
    expect(picker({ 0 => [:outer], 1 => [:outer] }).pick([0, 1], [], [0], :plain)).to eq(:skip)
  end

  it "still satisfies every atom for a group that isn't a near miss" do
    expect(picker({ 0 => [:outer], 1 => [:inner] }).pick([0, 1], [], nil, :plain)).to eq("open")
  end
end
