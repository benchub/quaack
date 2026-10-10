# frozen_string_literal: true

require "quaack/enclave/scenario_tests"

# Columns with the same CHECK text share one cached probe only when their
# types match (20261004-6). A probe binds the value as the column's type, so
# an integer column and a bigint column answer differently for 3000000000, and
# varchar(8) and varchar(255) differ in which values they can read.
RSpec.describe Quaack::Enclave::Scenarios::Checks do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:names) { %w[ints bigs short long].map { Quaack::Enclave::TableName.new(schema: "pk", name: it) } }
  let(:schema) { Quaack::Enclave::ArenaSchema.load_closure(conn, names) }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA pk;
      CREATE TABLE pk.ints (id bigserial PRIMARY KEY, n integer NOT NULL CHECK (n >= 2));
      CREATE TABLE pk.bigs (id bigserial PRIMARY KEY, n bigint NOT NULL CHECK (n >= 2));
      CREATE TABLE pk.short (id bigserial PRIMARY KEY, n varchar(8) NOT NULL CHECK (n >= 'b'));
      CREATE TABLE pk.long (id bigserial PRIMARY KEY, n varchar(255) NOT NULL CHECK (n >= 'b'));
    SQL
  end

  def allows?(checks, name, value)
    table = names.find { it.name == name }
    checks.allows?(table, schema.column(table, "n"), value)
  end

  # 3000000000 is past integer, so the integer column's probe can't read it.
  [%w[ints bigs], %w[bigs ints]].each do |first, second|
    it "answers each type for itself when #{first} is asked before #{second}" do
      checks = described_class.new(conn, schema)
      answers = [first, second].to_h { [it, allows?(checks, it, "3000000000")] }
      expect(answers).to eq("ints" => false, "bigs" => true)
    end
  end

  it "keys a probe by the column's oid and its full type" do
    key = lambda do |name|
      table = names.find { it.name == name }
      node = PgQuery.parse("SELECT 1 WHERE n >= 'b'").tree.stmts[0].stmt.select_stmt.where_clause
      Quaack::Enclave::ValuePools::Probe.new(conn, node, schema.column(table, "n")).key
    end
    expect(key.call("short")).not_to eq(key.call("long"))
    expect(key.call("ints")).not_to eq(key.call("bigs"))
  end
end
