# frozen_string_literal: true

require "delegate"
require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"
require "quaack/enclave/vacuity_guard"
require "quaack/enclave/egress"

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
    [builder, described_class.run(runner, builder, sql, search: false)]
  end

  it "passes a fixture that exercises every atom, with no retries" do
    _, result = guard("SELECT o.id FROM fx.orders o JOIN fx.customers c ON c.id = o.customer_id " \
                      "WHERE o.status = 'open' AND o.qty > 2")
    expect(result.untested).to eq([])
    expect(result.retries).to eq(0)
    expect(result.scenarios[:s1]).not_to be_empty
  end

  it "records no load failure and the original's row count on S1 when the fixture loads" do
    sql = "SELECT o.id FROM fx.orders o JOIN fx.customers c ON c.id = o.customer_id " \
          "WHERE o.status = 'open' AND o.qty > 2"
    _, result = guard(sql)
    expected = runner.with_fixture(result.scenarios[:s1]) { |tx| tx.query(sql).rows.size }

    expect(result.s1_load_rule).to be_nil
    expect(result.s1_rows).to eq([expected, 2].min)
    expect(result.s1_rows).to be_positive
  end

  # 20261010-22: s1_rows is 1 for any aggregate, so s1_nonzero_rows counts
  # the rows of the original's S1 result with a value that's neither NULL nor
  # a numeric zero: 0 means S1 matched nothing, whatever the aggregate.
  [["count(*)", "count(*)"], ["sum()", "sum(o.qty)"], ["max()", "max(o.qty)"]].each do |name, agg|
    it "records #{name} on S1 as one nonzero row when the hit matches, and zero when nothing can" do
      hit = "SELECT #{agg} FROM fx.orders o WHERE o.status = 'open' AND o.qty > 2"
      miss = "SELECT #{agg} FROM fx.orders o WHERE o.status = 'open' AND o.id IS NULL"

      expect(guard(hit).last).to have_attributes(s1_rows: 1, s1_nonzero_rows: 1)
      expect(guard(miss).last).to have_attributes(s1_rows: 1, s1_nonzero_rows: 0)
    end
  end

  it "records a non-aggregate's nonzero rows as its row count" do
    _, result = guard("SELECT o.id, o.status FROM fx.orders o WHERE o.status = 'open' AND o.qty > 2")

    expect(result.s1_nonzero_rows).to eq(result.s1_rows)
    expect(result.s1_nonzero_rows).to be_positive
  end

  it "counts as nonzero only rows with a value that's neither NULL nor a numeric zero" do
    rows = [["0"], [nil], ["0.00", nil], ["-0"], [0], ["7"], [nil, "0", "x"], ["00.5"]]
    expect(described_class.nonzero_rows(rows)).to eq(3)
  end

  it "gives a bare count for rows of data, never a value from them" do
    count = described_class.nonzero_rows([["SENTINEL_9c"], ["0"], ["SENTINEL_9c", nil]])
    expect(count).to eq(2)
    expect(Quaack::Protocol::VacuityDiagnostic.valid?({ "s1_nonzero_rows" => count })).to be(true)
    expect(Quaack::Enclave::Egress.serialize(type: :rewrite_test, rewrite: "rewrite_1", passed: true,
                                             s1_nonzero_rows: count)).not_to include("SENTINEL_9c")
  end

  it "records the rule S1 failed to load with, and no row count, never the error's message" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.gated (id integer PRIMARY KEY, label text NOT NULL);
      CREATE FUNCTION fx.refuse() RETURNS trigger LANGUAGE plpgsql
        AS $$ BEGIN RAISE EXCEPTION 'SENTINEL_9c refused'; END $$;
      CREATE TRIGGER refuse BEFORE INSERT ON fx.gated FOR EACH ROW EXECUTE FUNCTION fx.refuse();
    SQL
    _, result = guard("SELECT g.id FROM fx.gated g WHERE g.label = 'a' AND g.id > 3")

    expect(result.untested.size).to eq(2)
    expect(result.s1_load_rule).to eq(:fixture_load_failed)
    expect(result.s1_rows).to be_nil
    expect(result.s1_nonzero_rows).to be_nil
    expect(result.inspect).not_to include("SENTINEL_9c")
  end

  # Only the runner is faked, the edge to the arena: attempts[n] says whether
  # the nth load fails (with a rule) or loads, and a loaded fixture returns
  # rows (an Integer, or one per attempt) rows for every query, so every atom
  # stays vacuous and the guard makes all of its four attempts.
  def faked_runner(attempts, rows: 4)
    calls = 0
    tx_for = method(:faked_tx)
    Object.new.tap do |runner|
      runner.define_singleton_method(:with_fixture) do |_rows, **, &block|
        attempt = (calls += 1) - 1
        failure = attempts.fetch(attempt)
        raise Quaack::Enclave::ArenaRunner::Error.new(failure, step: :load), cause: nil if failure

        block.call(tx_for.call(Array(rows).fetch(attempt) { Array(rows).first }))
      end
    end
  end

  # A transaction whose every query returns count rows.
  def faked_tx(count)
    result = Struct.new(:rows).new(Array.new(count) { [it] })
    Struct.new(:result) { def query(_sql) = result }.new(result)
  end

  def guard_with(runner)
    sql = "SELECT o.id FROM fx.orders o WHERE o.status = 'open' AND o.qty > 2"
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    described_class.run(runner, builder, sql, search: false)
  end

  it "records :other for a load failure with a rule off the fixed list, and the wire message carries \"other\"" do
    off_list = :statement_not_allowed
    expect(Quaack::Protocol::VacuityDiagnostic::LOAD_RULES).not_to include(off_list.to_s)
    result = guard_with(faked_runner([off_list] * 4))

    expect(result.s1_load_rule).to eq(:other)
    out = Quaack::Enclave::Egress.serialize(type: :rewrite_test, rewrite: "rewrite_1", passed: false,
                                            s1_load_rule: result.s1_load_rule.to_s, s1_rows: result.s1_rows)
    expect(JSON.parse(out)).to include("s1_load_rule" => "other", "s1_rows" => nil)
  end

  it "keeps a rule that is on the list as it is" do
    expect(guard_with(faked_runner([:statement_timeout] * 4)).s1_load_rule).to eq(:statement_timeout)
  end

  it "records the last attempt: a load that failed early and loaded later has no rule and a row count" do
    result = guard_with(faked_runner([:fixture_load_failed, :fixture_load_failed, :statement_timeout, nil], rows: 4))

    expect(result.retries).to be_positive
    expect(result.s1_load_rule).to be_nil
    expect(result.s1_rows).to eq(1)
  end

  it "records the last attempt: a load that worked early and failed later has the rule and no row count" do
    result = guard_with(faked_runner([nil, nil, nil, :statement_timeout], rows: 4))

    expect(result.s1_load_rule).to eq(:statement_timeout)
    expect(result.s1_rows).to be_nil
  end

  # 20261010-35: S1's rows can follow the query's literals, so both counts
  # go out as 0, or 1 for one or more, never the count itself.
  it "reports S1's counts as 0 or 1, whatever the number of rows" do
    reported = [0, 1, 2, 3, 7, 1000].map do |rows|
      result = guard_with(faked_runner([nil] * 4, rows:))
      [result.s1_rows, result.s1_nonzero_rows]
    end
    expect(reported).to eq([[0, 0], [1, 0], [1, 1], [1, 1], [1, 1], [1, 1]])
  end

  it "records the last attempt's row count, not the first's" do
    result = guard_with(faked_runner([nil, nil, nil, nil], rows: [4, 4, 4, 0]))

    expect(result.s1_rows).to eq(0)
    expect(result.s1_nonzero_rows).to eq(0)
  end

  it "records the later count when the first attempt loaded, an intermediate one failed, and the last loaded" do
    result = guard_with(faked_runner([nil, :fixture_load_failed, :fixture_load_failed, nil], rows: [0, 0, 0, 2]))

    expect(result.s1_load_rule).to be_nil
    expect(result.s1_rows).to eq(1)
  end

  it "records the last failure's rule, not the first's" do
    result = guard_with(faked_runner(%i[fixture_load_failed fixture_load_failed fixture_load_failed statement_timeout]))

    expect(result.s1_load_rule).to eq(:statement_timeout)
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
    expect(result.untested_atoms.count(natural)).to eq(1)
    expect(result.untested.count("NATURAL JOIN")).to eq(1)
    # It's never rebuilt: only o.status = $1 gets retries.
    expect(result.variants.keys).not_to include(natural)
    expect(result.retries).to eq(3)
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
    # The first near miss for qty > 2 is 2, and its status takes the text
    # type's typical value, two characters long, so qty <> length(status)
    # filters it out anyway. (A group's own key used to serve here, but it
    # now steers clear of pooled values, 20261010-47.)
    # The next pool value, 1, gets through once qty > 2 is TRUE. The
    # two-column test has no pool, so no rebuild helps it.
    builder, result = guard("SELECT o.id FROM fx.orders o WHERE o.qty > 2 AND o.qty <> length(o.status)")
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
    result = described_class.run(runner, rebuilds, sql, search: false)
    expect(result.untested_atoms).to eq([0])
    expect(result.retries).to eq(3)
  end

  it "raises a query that fails on the loaded fixture, instead of reporting its atoms untested" do
    # Division by zero fails at the query step, after the fixture loaded.
    # Only a load failure may be read as "exercised nothing".
    expect { guard("SELECT o.id FROM fx.orders o WHERE o.qty / 0 > 1 AND o.status = 'open'") }
      .to raise_error(Quaack::Enclave::ArenaRunner::Error) { |e| expect([e.rule, e.step]).to eq(%i[query_failed query]) }
  end
end
