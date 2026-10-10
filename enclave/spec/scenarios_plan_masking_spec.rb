# frozen_string_literal: true

require "quaack/enclave/scenarios"

# Masking near misses (20261010-19) come last in every scenario that holds
# them, so on a unique-key collision they're the groups left out. The
# topology is an input, made here with one table and no joins; the Plan is real.
RSpec.describe Quaack::Enclave::Scenarios::Plan do
  topology_class = Class.new do
    def order = [:t]
    def roots = [:t]
    def crossings = []
    def free_joins = []
  end

  it "puts the masking near misses after every other group of S1 through S5" do
    scenarios = described_class.new(topology_class.new, [], [0, 1], { 0 => [1] }).scenarios
    %i[s1 s2 s3 s4 s5].each do |name|
      groups = scenarios.fetch(name)
      expect(groups.last.also).to eq([1]), name.to_s
      expect(groups[0...-1].map(&:also)).to all(eq([])), name.to_s
    end
    expect(scenarios[:s6].map(&:also)).to all(eq([]))
  end
end
