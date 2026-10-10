# frozen_string_literal: true

require "quaack/protocol/unchanged_atoms"

# The one check on a report rewrite's untested_unchanged (DESIGN.md,
# unchanged-atoms): it may only repeat shapes the entry's untested_atoms
# already sent, so it can't carry a literal or any other text.
RSpec.describe Quaack::Protocol::UnchangedAtoms do
  let(:sentinel) { "SENTINEL_UNCHANGED_77d1" }

  def valid?(*entries) = described_class.valid?(entries)

  it "takes an entry with no untested_unchanged, a nil one, or an empty one" do
    expect(valid?({ "untested_atoms" => ["a < $1"] }, { "untested_atoms" => nil, "untested_unchanged" => nil },
                  { "untested_atoms" => [], "untested_unchanged" => [] })).to be(true)
  end

  it "takes shapes that are among the entry's untested_atoms, with String or Symbol keys" do
    expect(valid?({ "untested_atoms" => ["a < $1", "b = $2"], "untested_unchanged" => ["b = $2"] })).to be(true)
    expect(valid?({ untested_atoms: ["a < $1"], untested_unchanged: ["a < $1"] })).to be(true)
  end

  it "refuses a shape the entry never sent as untested, quoting nothing" do
    expect(valid?({ "untested_atoms" => ["a < $1"], "untested_unchanged" => [sentinel] })).to be(false)
    expect(valid?({ "untested_atoms" => ["a < $1"], "untested_unchanged" => ["a < $1", sentinel] })).to be(false)
  end

  it "refuses unchanged shapes when untested_atoms is missing, or either isn't an Array of Strings" do
    [{ "untested_unchanged" => ["a < $1"] },
     { "untested_atoms" => nil, "untested_unchanged" => ["a < $1"] },
     { "untested_atoms" => ["a < $1"], "untested_unchanged" => "a < $1" },
     { "untested_atoms" => ["a < $1"], "untested_unchanged" => [1] },
     { "untested_atoms" => ["a < $1"], "untested_unchanged" => { "a < $1" => true } }].each do |entry|
      expect(valid?(entry)).to be(false), entry.inspect
    end
  end

  it "refuses when any one entry fails, and anything that isn't an Array of Hashes" do
    good = { "untested_atoms" => ["a < $1"], "untested_unchanged" => ["a < $1"] }
    bad = { "untested_atoms" => [], "untested_unchanged" => [sentinel] }

    expect(valid?(good, bad)).to be(false)
    expect([nil, "x", [1], { "untested_unchanged" => [] }].map { described_class.valid?(it) }).to eq([false] * 4)
  end
end
