# frozen_string_literal: true

require "quaack/protocol/suggested_drops"

# The one check on a report label's suggested_drops, for the enclave's
# egress function and the driver both: index names and counts, nothing else.
RSpec.describe Quaack::Protocol::SuggestedDrops do
  let(:entry) { { "name" => "orders_created_at_idx", "size_bytes" => 40_960, "idx_scan" => 12 } }

  def valid?(value) = described_class.valid?(value)

  it "passes none, and entries with a name and two counts, either count nil" do
    expect(valid?([])).to be(true)
    expect(valid?([entry, entry.merge("size_bytes" => nil, "idx_scan" => nil)])).to be(true)
  end

  [
    ["a planted key", ->(e) { e.merge("predicate" => "status = 'x'") }],
    ["no idx_scan", ->(e) { e.except("idx_scan") }],
    ["a Symbol key", ->(e) { e.except("name").merge(name: "x") }],
    ["a String idx_scan", ->(e) { e.merge("idx_scan" => "12") }],
    ["a Float size", ->(e) { e.merge("size_bytes" => 1.5) }],
    ["a negative count", ->(e) { e.merge("idx_scan" => -1) }],
    ["a huge count", ->(e) { e.merge("idx_scan" => 10**15) }],
    ["a name that isn't a String", ->(e) { e.merge("name" => ["x"]) }],
    ["a name longer than an identifier", ->(e) { e.merge("name" => "a" * 64) }],
    ["a non-Hash entry", ->(_) { "orders_idx" }]
  ].each do |what, change|
    it "refuses #{what}" do
      expect(valid?([change.call(entry)])).to be(false)
    end
  end

  it "refuses a value that isn't an Array" do
    expect([nil, "x", entry].map { valid?(it) }).to eq([false, false, false])
  end
end
