# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"
require "quaack/enclave/vacuity_guard"

# 9c: on S1, each atom must change the original's result when it's replaced
# by TRUE. One that doesn't is retried with other pool values, up to three
# times, and then reported as untested by its redacted shape.
RSpec.describe Quaack::Enclave::VacuityGuard do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.customers (id integer PRIMARY KEY, name text NOT NULL);
      CREATE TABLE fx.orders (id integer PRIMARY KEY, customer_id integer NOT NULL REFERENCES fx.customers,
        status text NOT NULL, qty integer NOT NULL CHECK (qty >= 0),
        kind text NOT NULL CHECK (kind IN ('SENTINEL_9c')));
    SQL
  end

  def guard(sql)
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    [builder, described_class.run(runner, builder, sql)]
  end

  it "passes a fixture that exercises every atom, with no retries" do
    _, result = guard("SELECT o.id FROM fx.orders o JOIN fx.customers c ON c.id = o.customer_id " \
                      "WHERE o.status = 'open' AND o.qty > 2")
    expect(result.untested).to eq([])
    expect(result.retries).to eq(0)
    expect(result.scenarios[:s1]).not_to be_empty
  end

  it "retries a vacuous atom three times, then reports it untested by its redacted shape" do
    # No row can fail either kind test, since the CHECKs forbid it.
    sql = "SELECT o.id FROM fx.orders o WHERE o.kind = 'SENTINEL_9c' AND o.status = 'open'"
    builder, result = guard(sql)
    expect(result.untested).to eq([builder.atoms[0].shape])
    expect(result.untested_atoms).to eq([0])
    expect(result.retries).to eq(3)
    expect(result.untested.join).not_to include("SENTINEL_9c")
  end

  it "keeps an atom a retry exercises, with other pool values" do
    # The first near miss for qty > 2 is 2, and its group key, so its
    # customer_id, is 2 too, so qty <> customer_id filters it out anyway.
    # The next pool value, 1, gets through once qty > 2 is TRUE. The
    # two-column test has no pool, so no rebuild helps it.
    builder, result = guard("SELECT o.id FROM fx.orders o WHERE o.qty > 2 AND o.qty <> o.customer_id")
    expect(result.untested).to eq([builder.atoms[1].shape])
    expect(result.retries).to eq(4)
    expect(result.variants).to eq({ 0 => 1, 1 => 3 })
  end
end
