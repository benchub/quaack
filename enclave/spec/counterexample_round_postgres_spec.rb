# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/counterexamples"
require "quaack/enclave/predicate_atoms"

# 10b and 10c: load one round's counterexamples, compare with 9d, recheck
# 9c's untested atoms on them, and roll back.
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

  it "reports an insert that fails to load by the runner's rule" do
    prepared = described_class::Prepared.new(
      rows: [], inserts: ["INSERT INTO fx.orders (id, status) VALUES (1, 'a'), (1, 'b')"], refused: []
    )
    result = described_class.compare(runner, prepared, original:, candidate: lowered, atoms:, untested: [0])
    expect([result.match, result.rule, result.covered]).to eq([false, :insert_failed, []])
  end
end
