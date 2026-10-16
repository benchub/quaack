# frozen_string_literal: true

require "quaack/protocol/tablespace_moves"

# Task 20261010-17: the one check on the report's tablespace_moves, for the
# enclave's egress function and the driver both: schema.name table names,
# as quote_ident writes them, and never a tablespace's name or a value.
RSpec.describe Quaack::Protocol::TablespaceMoves do
  def valid?(value) = described_class.valid?(value)

  it "passes none, and bare or quoted schema.name names" do
    expect(valid?([])).to be(true)
    expect(valid?(["public.orders", %(sales."Order ""Lines"""), %("My Schema".t_1$)])).to be(true)
  end

  [
    ["a name with no schema", "orders"],
    ["a name with three parts", "a.b.c"],
    ["an uppercase bare name", "public.Orders"],
    ["a quoted name with a lone quote mark", %(public."a"b")],
    ["a name with a space outside quotes", "public.my orders"],
    ["a non-ASCII quoted name", %(public."caf\u00e9")],
    ["a control character", %(public."a\nb")],
    ["a name that isn't a String", ["public.orders"]],
    ["an empty String", ""]
  ].each do |what, name|
    it "refuses #{what}" do
      expect(valid?([name])).to be(false)
    end
  end

  it "refuses a value that isn't an Array, and more than 64 names" do
    expect([nil, "public.orders", { "public.orders" => 1 }].map { valid?(it) }).to eq([false, false, false])
    expect(valid?(["public.orders"] * 65)).to be(false)
    expect(valid?(["public.orders"] * 64)).to be(true)
  end

  # Review of 20261010-17: a well-formed name isn't enough. Each must be a table
  # the report's own query names, given as [schema, name] pairs.
  describe ".within?" do
    let(:tables) { [%w[public orders], ["sales", %(Order "Lines")], %w[public user]] }

    it "passes names of the given tables, as quote_ident writes them" do
      expect(described_class.within?(["public.orders", %(sales."Order ""Lines"""), %(public."user")], tables))
        .to be(true)
      expect(described_class.within?([], [])).to be(true)
    end

    it "refuses a well-formed name of another table, and a field valid? refuses" do
      expect(described_class.within?(["private.sentinel_8f3a2c_payroll"], tables)).to be(false)
      expect(described_class.within?(["public.orders", "public.customers"], tables)).to be(false)
      expect(described_class.within?([%(public."Orders")], tables)).to be(false)
      expect(described_class.within?(["orders"], [%w[public orders]])).to be(false)
      expect(described_class.within?(nil, tables)).to be(false)
      expect(described_class.within?(["public.orders"] * 65, tables)).to be(false)
    end
  end
end
