# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/counterexamples"
require "quaack/enclave/predicate_atoms"

# counterexample-compare and counterexample-rollback: load one round's counterexamples, compare with fixture-compare,
# recheck vacuity-guard's untested atoms on them, and roll back.
RSpec.describe Quaack::Enclave::Counterexamples, ".compare" do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }
  let(:original) { "SELECT o.id FROM fx.orders o WHERE o.status = 'SENTINEL_10b'" }
  let(:atoms) do
    orders = Quaack::Enclave::TableName.new(schema: "fx", name: "orders")
    Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(original), column_names: { orders => %w[id status] })
  end

  before { conn.exec("CREATE SCHEMA fx; CREATE TABLE fx.orders (id integer PRIMARY KEY, status text NOT NULL)") }

  def round(candidate, *values)
    inserts = values.each_with_index.map { |v, i| "INSERT INTO fx.orders (id, status) VALUES (#{i + 1}, '#{v}')" }
    prepared = described_class::Prepared.new(rows: [], inserts:, refused: [])
    described_class.compare(runner, prepared, original:, candidate:, atoms:, untested: [0])
  end

  let(:lowered) { "SELECT o.id FROM fx.orders o WHERE lower(o.status) = lower('SENTINEL_10b')" }

  it "disproves a candidate the inserts tell apart, and records the untested atom they cover" do
    result = round(lowered, "SENTINEL_10b", "sentinel_10b")
    expect([result.match, result.rule]).to eq([false, :row_count])
    expect(result.covered).to eq([atoms[0].shape])
    expect(result.to_h.to_s).not_to include("SENTINEL_10b")
  end

  it "matches when the inserts don't tell them apart, covering nothing new, and leaves arena empty" do
    result = round(lowered, "SENTINEL_10b")
    expect([result.match, result.covered]).to eq([true, []])
    expect(conn.exec("SELECT count(*) FROM fx.orders").getvalue(0, 0)).to eq("0")
  end

  it "reports an insert that fails to load as a load failure, not a mismatch" do
    prepared = described_class::Prepared.new(
      rows: [], inserts: ["INSERT INTO fx.orders (id, status) VALUES (1, 'a'), (1, 'b')"], refused: []
    )
    result = described_class.compare(runner, prepared, original:, candidate: lowered, atoms:, untested: [0])
    expect([result.match, result.load_failed, result.rule, result.covered]).to eq([nil, true, :insert_failed, []])
  end
  it "reports an insert that hits the statement timeout as a load failure, not a disproof" do
    slow = Quaack::Enclave::ArenaRunner.new(conn, statement_timeout_ms: 50)
    prepared = described_class::Prepared.new(
      rows: [], inserts: ["INSERT INTO fx.orders (id, status) SELECT 1, pg_sleep(1)::text"], refused: []
    )
    result = described_class.compare(slow, prepared, original:, candidate: lowered, atoms:, untested: [0])
    expect([result.match, result.load_failed, result.rule]).to eq([nil, true, :statement_timeout])
  end

  it "reports a parent row that hits the statement timeout while loading as a load failure, not a disproof" do
    conn.exec("CREATE TABLE fx.slow (id integer CHECK (length(pg_sleep(1)::text) >= 0))")
    slow = Quaack::Enclave::ArenaRunner.new(conn, statement_timeout_ms: 50)
    row = Quaack::Enclave::ArenaRunner::FixtureRow.new(
      table: Quaack::Enclave::TableName.new(schema: "fx", name: "slow"), columns: ["id"], values: ["1"]
    )
    prepared = described_class::Prepared.new(rows: [row], inserts: [], refused: [])
    result = described_class.compare(slow, prepared, original:, candidate: lowered, atoms:, untested: [0])
    expect([result.match, result.load_failed, result.rule]).to eq([nil, true, :statement_timeout])
  end

  it "skips an untested atom that can't be replaced by TRUE" do
    using = "SELECT o.id FROM fx.orders o JOIN fx.orders p USING (status) WHERE o.status = 'SENTINEL_10b'"
    orders = Quaack::Enclave::TableName.new(schema: "fx", name: "orders")
    using_atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(using),
                                                          column_names: { orders => %w[id status] })
    fixed = using_atoms.each_index.reject { |i| using_atoms[i].replaceable }
    expect(fixed).not_to be_empty
    prepared = described_class::Prepared.new(
      rows: [], inserts: ["INSERT INTO fx.orders (id, status) VALUES (1, 'SENTINEL_10b'), (2, 'other')"], refused: []
    )
    result = described_class.compare(runner, prepared, original: using, candidate: using, atoms: using_atoms,
                                                       untested: using_atoms.each_index.to_a)
    expect(result.covered).not_to include(*fixed.map { |i| using_atoms[i].shape })
    expect(result.covered).not_to be_empty
  end

  it "still disproves a candidate that fails to run" do
    prepared = described_class::Prepared.new(rows: [], inserts: ["INSERT INTO fx.orders (id, status) VALUES (1, 'a')"],
                                             refused: [])
    result = described_class.compare(runner, prepared, original:, candidate: "SELECT o.id / 0 FROM fx.orders o",
                                                       atoms:, untested: [0])
    expect([result.match, result.load_failed, result.rule]).to eq([false, false, :query_failed])
  end
end
