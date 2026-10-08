# frozen_string_literal: true

require "delegate"
require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"
require "quaack/enclave/vacuity_guard"

# vacuity-guard: on S1, each atom must change the original's result when it's replaced
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

  it "exercises a keyset row comparison through its leading column, in either direction" do
    %w[< <= > >=].each do |op|
      sql = "SELECT o.id FROM fx.orders o WHERE (o.qty, o.id) #{op} (5, 10) ORDER BY o.qty, o.id LIMIT 20"
      builder, result = guard(sql)
      expect(builder.atoms.map(&:kind)).to eq([:row_comparison])
      expect(result.untested).to eq([]), op
      expect(builder.pools.keys).to eq([0])
    end
  end

  it "pools a row comparison's leading column by the values that decide it, leaving out the tie" do
    { "<=" => %i[< >], ">" => %i[> <], "<" => %i[< >] }.each do |op, (satisfies, fails)|
      builder, = guard("SELECT o.id FROM fx.orders o WHERE (o.qty, o.id) #{op} (5, 10)")
      pool = builder.pools.fetch(0)
      expect(pool.satisfying.map(&:to_i)).to all(be.send(satisfies, 5)), op
      expect(pool.failing.map(&:to_i)).to all(be.send(fails, 5)), op
      # The literal's neighbors, one on each side of the tie.
      expect((pool.satisfying + pool.failing) & %w[4 6]).to contain_exactly("4", "6"), op
    end
  end

  it "gives a row comparison with = or <>, or with an expression in its row, no pool" do
    builder, = guard("SELECT o.id FROM fx.orders o WHERE (o.qty, o.id) = (5, 10) OR (o.qty, o.id) <> (1, 2) " \
                     "OR (o.qty + 1, o.id) < (5, 10)")
    expect(builder.atoms.map(&:kind)).to eq(%i[row_comparison row_comparison row_comparison])
    expect(builder.pools).to eq({})
  end

  # Task 20260926-56: PredicateAtoms refuses to replace it with its own Error.
  it "reports a JOIN ... USING column untested, since it can't be replaced by TRUE" do
    builder, result = guard("SELECT o.id FROM fx.orders o JOIN fx.customers c USING (id) WHERE o.status = 'open'")
    expect(builder.atoms.map(&:replaceable)).to eq([true, false]).or eq([false, true])
    using = builder.atoms.index { !it.replaceable }
    expect(result.untested_atoms).to include(using)
    expect(result.untested).to include(builder.atoms[using].shape)
  end

  it "reports a NATURAL JOIN untested, since its condition isn't written in the query" do
    builder, result = guard("SELECT o.id FROM fx.orders o NATURAL JOIN fx.customers c WHERE o.status = 'open'")
    natural = builder.atoms.index { it.operator == "NATURAL" }
    expect(natural).not_to be_nil
    expect(result.untested_atoms).to include(natural)
    expect(result.untested).to include("NATURAL JOIN")
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

  it "keeps an atom exercised once exercised, even when a rebuild's fixture no longer exercises it" do
    # The rebuilds return no rows at all, so they exercise nothing. The
    # status test, exercised by the first build, must stay exercised.
    sql = "SELECT o.id FROM fx.orders o WHERE o.kind = 'SENTINEL_9c' AND o.status = 'open'"
    real = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    rebuilds = Class.new(SimpleDelegator) do
      def build(variants)
        scenarios = __getobj__.build(variants)
        variants.empty? ? scenarios : scenarios.merge(s1: [])
      end
    end.new(real)
    result = described_class.run(runner, rebuilds, sql)
    expect(result.untested_atoms).to eq([0])
    expect(result.retries).to eq(3)
  end
end
