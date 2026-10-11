# frozen_string_literal: true

require "quaack/protocol/untested_states"

# How each untested atom stayed unproven (20261010-43): a report rewrite's
# untested_states holds one fixed word per untested atom, so it carries no
# text of its own.
RSpec.describe Quaack::Protocol::UntestedStates do
  let(:sentinel) { "SENTINEL_STATES_43a" }

  def valid?(*entries) = described_class.valid?(entries)

  it "names the fixed words" do
    expect(described_class::WORDS).to eq(%w[searched not_searched])
  end

  it "takes an entry with no untested_states, as older messages have, or a nil one" do
    expect(valid?({ "untested_atoms" => ["a < $1"] }, { "untested_atoms" => ["a < $1"], "untested_states" => nil }))
      .to be(true)
  end

  it "takes one fixed word per untested atom, with String or Symbol keys" do
    expect(valid?({ "untested_atoms" => ["a < $1", "b = $2"], "untested_states" => %w[searched not_searched] }))
      .to be(true)
    expect(valid?({ untested_atoms: ["a < $1"], untested_states: ["searched"] })).to be(true)
  end

  it "refuses a word off the list, a count that doesn't match, or a value that isn't a list of Strings" do
    [{ "untested_atoms" => ["a < $1"], "untested_states" => [sentinel] },
     { "untested_atoms" => ["a < $1"], "untested_states" => %w[searched searched] },
     { "untested_atoms" => ["a < $1"], "untested_states" => [] },
     { "untested_states" => ["searched"] },
     { "untested_atoms" => ["a < $1"], "untested_states" => sentinel },
     { "untested_atoms" => ["a < $1"], "untested_states" => [{ "v" => sentinel }] }].each do |entry|
      expect(valid?(entry)).to be(false), entry.inspect
    end
  end

  it "refuses rewrites that aren't an Array of Hashes" do
    expect(described_class.valid?(nil)).to be(false)
    expect(described_class.valid?([sentinel])).to be(false)
  end
end
