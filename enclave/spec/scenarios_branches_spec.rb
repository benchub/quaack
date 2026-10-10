# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/predicate_atoms"
require "quaack/enclave/scenarios"

# Scopes and masking near misses (20261010-19), on parses alone.
RSpec.describe Quaack::Enclave::Scenarios::Branches do
  table = ->(name) { Quaack::Enclave::TableName.new(schema: "fx", name:) }
  columns = { table.call("a") => %w[id t w m], table.call("s") => %w[id aid w], table.call("c") => %w[id sid k] }

  def atoms_of(sql, columns) = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(sql), column_names: columns)

  def also(sql, columns, index, pooled: nil, &fits)
    atoms = atoms_of(sql, columns)
    branches = described_class.new(PgQuery.parse(sql).tree, atoms, pooled || atoms.each_index.to_a)
    fits ||= ->(_) { true }
    branches.also(index, &fits)
  end

  it "gives a join's ON atoms, at any depth, their SELECT's scope, and a UNION branch its own" do
    sql = "SELECT 1 FROM fx.a JOIN fx.s ON s.aid = a.id JOIN fx.c ON c.sid = s.id AND c.k = 1 WHERE a.t = 'x' " \
          "AND a.id IN (SELECT a.id FROM fx.a WHERE a.t = 'x' UNION ALL SELECT a.id FROM fx.a WHERE a.t = 'x')"
    scopes = Quaack::Enclave::Scenarios.scopes(atoms_of(sql, columns)).values
    expect(scopes.first(5).uniq.size).to eq(1)
    expect(scopes.drop(5).uniq.size).to eq(2)
    expect(scopes.drop(5)).not_to include(scopes.first)
  end

  it "fails an atom of the other UNION branch, and of each other OR arm" do
    union = "SELECT 1 FROM fx.a WHERE a.id IN (SELECT a.id FROM fx.a WHERE a.t = 'x' " \
            "UNION ALL SELECT a.id FROM fx.a WHERE a.w <> 'd' AND a.m)"
    expect(also(union, columns, 1)).to eq([2])
    expect(also(union, columns, 3)).to eq([1])
    expect(also("SELECT 1 FROM fx.a WHERE a.t = 'x' OR a.w <> 'd' OR a.m", columns, 1)).to eq([0, 2])
  end

  it "takes the next atom of an arm when the first can't be failed with it" do
    union = "SELECT 1 FROM fx.a WHERE a.id IN (SELECT a.id FROM fx.a WHERE a.t = 'x' " \
            "UNION ALL SELECT a.id FROM fx.a WHERE a.w <> 'd' AND a.m)"
    expect(also(union, columns, 1) { |chosen| chosen != [2] }).to eq([3])
    expect(also(union, columns, 1) { false }).to be_nil
  end

  # 20261010-23: a value can satisfy at most one of a.t = 1 .. a.t = 4, so
  # a partial choice that leaves two of them to satisfy never builds.
  it "looks ahead when no partial choice builds, as with four equality arms on one column" do
    sql = "SELECT 1 FROM fx.a WHERE a.t = '1' OR a.t = '2' OR a.t = '3' OR a.t = '4' OR a.w = 'z'"
    fits = ->(chosen) { ([0, 1, 2, 3] - [0] - chosen).size <= 1 }
    expect(also(sql, columns, 0, &fits)).to eq([1, 2, 3, 4])
    expect(also(sql, columns, 0) { |chosen| chosen.size == 4 }).to eq([1, 2, 3, 4])
    expect(also(sql, columns, 0) { |chosen| chosen.size == 4 && chosen != [1, 2, 3, 4] }).to be_nil
  end

  it "keeps the one-arm-at-a-time choice when it finds one" do
    sql = "SELECT 1 FROM fx.a WHERE a.t = 'x' OR (a.w <> 'd' AND a.m) OR (a.id = 5 AND a.id <> 6)"
    expect(also(sql, columns, 0) { |chosen| chosen != [1, 3] }).to eq([1, 4])
  end

  it "needs nothing more for a NOT arm, and gives up on an arm with no ANDed atom" do
    expect(also("SELECT 1 FROM fx.a WHERE a.t = 'x' OR NOT a.m", columns, 0)).to be_nil
    expect(also("SELECT 1 FROM fx.a WHERE a.t = 'x' OR (a.w = 'd' OR a.m)", columns, 0)).to be_nil
    expect(also("SELECT 1 FROM fx.a WHERE a.t = 'x' AND a.w = 'd'", columns, 0)).to be_nil
  end

  it "fails first an atom on a column no other atom tests" do
    union = "SELECT 1 FROM fx.a WHERE a.t = 'x' AND a.id IN (SELECT a.id FROM fx.a WHERE a.w = 'd' " \
            "UNION ALL SELECT a.id FROM fx.a WHERE a.t = 'x' AND a.m)"
    expect(also(union, columns, 2)).to eq([4])
  end

  it "fails only pooled atoms" do
    expect(also("SELECT 1 FROM fx.a WHERE a.t = 'x' OR (a.w = 'd' AND a.m)", columns, 0, pooled: [0, 2])).to eq([2])
  end
end
