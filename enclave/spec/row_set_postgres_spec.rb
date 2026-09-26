# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"

# RowSet leaves out a group whose row collides with an earlier one on a
# unique key, read from arena's catalog, including expression, INCLUDE,
# partial, and NULLS NOT DISTINCT unique indexes.
RSpec.describe Quaack::Enclave::Scenarios::RowSet do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:table) { Quaack::Enclave::TableName.new(schema: "fx", name: "t") }

  before { conn.exec("CREATE SCHEMA fx") }

  def row_set(ddl)
    conn.exec(ddl)
    described_class.new(Quaack::Enclave::ArenaSchema.load_closure(conn, [table]), conn)
  end

  def row(**pairs)
    Quaack::Enclave::ArenaRunner::FixtureRow.new(table:, columns: pairs.keys.map(&:to_s), values: pairs.values)
  end

  def adds(set, *rows) = rows.map { |r| set.add?([r]) }

  it "catches rows whose expression key collides though the column values differ" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, email text NOT NULL);
                   CREATE UNIQUE INDEX ON fx.t (lower(email))")
    expect(adds(set, row(id: "1", email: "A"), row(id: "2", email: "b"), row(id: "3", email: "a")))
      .to eq([true, true, false])
  end

  it "evaluates a multi-key expression index with a plain column key" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, email text, org integer);
                   CREATE UNIQUE INDEX ON fx.t (org, lower(email))")
    expect(adds(set, row(id: "1", email: "A", org: "1"), row(id: "2", email: "a", org: "2"),
                row(id: "3", email: "a", org: "1"), row(id: "4", email: nil, org: "1"),
                row(id: "5", email: nil, org: "1")))
      .to eq([true, true, false, true, true])
  end

  it "makes NULL keys collide under NULLS NOT DISTINCT" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, k integer UNIQUE NULLS NOT DISTINCT)")
    expect(adds(set, row(id: "1", k: nil), row(id: "2", k: nil))).to eq([true, false])
  end

  it "makes NULL expression keys collide under NULLS NOT DISTINCT" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, email text);
                   CREATE UNIQUE INDEX ON fx.t (lower(email)) NULLS NOT DISTINCT")
    expect(adds(set, row(id: "1", email: nil), row(id: "2", email: nil))).to eq([true, false])
  end

  it "lets NULL keys through without NULLS NOT DISTINCT" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, k integer UNIQUE)")
    expect(adds(set, row(id: "1", k: nil), row(id: "2", k: nil))).to eq([true, true])
  end

  it "keys a unique index on its key columns, not its INCLUDE columns" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, a integer, b integer);
                   CREATE UNIQUE INDEX ON fx.t (a) INCLUDE (b)")
    expect(adds(set, row(id: "1", a: "1", b: "7"), row(id: "2", a: "2", b: "7"), row(id: "3", a: "1", b: "8")))
      .to eq([true, true, false])
  end

  it "treats a partial unique index as always unique" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, a integer, live boolean);
                   CREATE UNIQUE INDEX ON fx.t (a) WHERE live")
    expect(adds(set, row(id: "1", a: "1", live: "f"), row(id: "2", a: "1", live: "f"))).to eq([true, false])
  end
end
