# frozen_string_literal: true

require "quaack/enclave/fuzz"

# Task 20261012-4's fix round: which of the loosened originals Coverage
# checks on a world give rows other than the original's (Fuzz::Differ). They
# go to the server in one statement, compared as multisets, and each that
# differs there is confirmed with the official comparison, so neither a
# tied row's order nor float noise counts as the atom mattering.
RSpec.describe Quaack::Enclave::Fuzz::Differ do
  let(:conn) { racetrack_and_arena.arena.connection }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA d;
      CREATE TABLE d.t (id integer PRIMARY KEY, g integer NOT NULL, f float8 NOT NULL, j json);
      INSERT INTO d.t VALUES (1, 1, 0.1, '{"a": 1}'), (2, 1, 0.2, '{"a": 2}'), (3, 2, 0.3, '{"a": 3}');
    SQL
    conn.exec("BEGIN")
  end

  after { conn.exec("ROLLBACK") }

  def differing(original, sqls) = described_class.differing(conn, original, sqls)

  it "names the queries whose rows differ, either way, by their indexes" do
    original = "SELECT d.t.id FROM d.t WHERE d.t.g = 1"
    sqls = ["SELECT d.t.id FROM d.t WHERE true", "SELECT d.t.id FROM d.t WHERE false",
            "SELECT d.t.id FROM d.t WHERE d.t.id < 3"]

    expect(differing(original, sqls)).to eq([0, 1])
  end

  it "counts a row's copies" do
    original = "SELECT d.t.g FROM d.t WHERE d.t.id <> 2"

    expect(differing(original, ["SELECT d.t.g FROM d.t WHERE true"])).to eq([0])
  end

  it "doesn't count tied rows in another order, under the original's ORDER BY" do
    original = "SELECT d.t.id FROM d.t ORDER BY d.t.g"

    expect(differing(original, ["SELECT d.t.id FROM d.t ORDER BY d.t.g, d.t.id DESC"])).to eq([])
  end

  it "doesn't count float noise the official comparison calls equal" do
    original = "SELECT sum(d.t.f) FROM d.t"
    noise = "SELECT 0.1::float8 + 0.2::float8 + 0.3::float8 - 1e-15::float8 AS sum"

    expect(differing(original, [noise])).to eq([])
  end

  it "compares a column with no equality operator, query by query, with the official comparison" do
    original = "SELECT d.t.j FROM d.t WHERE d.t.g = 1"
    sqls = ["SELECT d.t.j FROM d.t WHERE true", "SELECT d.t.j FROM d.t WHERE d.t.id < 3"]

    expect(differing(original, sqls)).to eq([0])
  end

  # Task 20261012-49: only a mismatch shows the atom mattered; a comparison
  # that refuses, as an ordered one does while any column uses a
  # nondeterministic collation, shows nothing.
  it "doesn't count rows the official comparison refuses to judge" do
    conn.exec(<<~SQL)
      CREATE COLLATION d.loose (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
      CREATE TABLE d.named (id integer PRIMARY KEY, name text COLLATE d.loose);
      INSERT INTO d.named VALUES (1, 'a'), (2, 'B');
    SQL
    original = "SELECT d.named.name FROM d.named WHERE d.named.id = 1 ORDER BY d.named.name"

    expect(differing(original, ["SELECT d.named.name FROM d.named WHERE true ORDER BY d.named.name"])).to eq([])
  end

  it "doesn't count a query that fails, and still judges the rest" do
    original = "SELECT d.t.id FROM d.t WHERE d.t.g = 1"
    sqls = ["SELECT d.t.id FROM d.t WHERE 1 / (d.t.g - 1) > 0", "SELECT d.t.id FROM d.t WHERE true"]

    expect(differing(original, sqls)).to eq([1])
    expect(conn.exec("SELECT count(*) FROM d.t").getvalue(0, 0)).to eq("3")
  end

  # Task 20261012-52: a cancel QUAACK didn't send, such as an operator's
  # pg_cancel_backend, says nothing about the atom, so it ends the step as
  # in fuzz's lift; QUAACK's own statement_timeout is still no difference.
  describe "with a canceled query" do
    let(:original) { "SELECT d.t.id FROM d.t WHERE d.t.g = 1" }
    let(:cancels) do
      "SELECT d.t.id FROM d.t WHERE CASE WHEN pg_cancel_backend(pg_backend_pid()) THEN " \
        "(SELECT count(*) FROM generate_series(1, 100000000 + d.t.id)) < 0 END"
    end
    let(:slow) { "SELECT d.t.id FROM d.t WHERE (SELECT count(*) FROM generate_series(1, 100000000 + d.t.id)) < 0" }

    def run(sqls, timeout_ms) = described_class.differing(conn, original, sqls, statement_timeout_ms: timeout_ms)

    it "ends the step on a cancel QUAACK didn't send, with statement_canceled" do
      expect { run([cancels], 60_000) }.to raise_error(Quaack::Enclave::ArenaRunner::Error) do |error|
        expect([error.rule, error.step]).to eq(%i[statement_canceled query])
      end
    end

    # Task 20261118-204800-1: each statement in the official comparison
    # gets its own clock mark, so a foreign cancel on the candidate, after
    # the original ran past the timeout, isn't read as QUAACK's timeout.
    # The candidate's first call fails the multiset statement, so the
    # official comparison runs; its second cancels itself.
    it "ends the step on a foreign cancel of the candidate after a slow original" do
      conn.exec(<<~SQL)
        CREATE SEQUENCE d.calls;
        CREATE FUNCTION d.cancel_later() RETURNS boolean LANGUAGE plpgsql AS $$
        BEGIN
          IF nextval('d.calls') = 1 THEN RAISE EXCEPTION 'first call'; END IF;
          PERFORM pg_cancel_backend(pg_backend_pid());
          PERFORM pg_sleep(5);
          RETURN true;
        END $$;
      SQL
      slow_original = "SELECT d.t.id FROM d.t, pg_catalog.pg_sleep(0.4)"
      candidate = "SELECT d.t.id FROM d.t WHERE d.cancel_later()"

      expect { described_class.differing(conn, slow_original, [candidate], statement_timeout_ms: 300) }
        .to raise_error(Quaack::Enclave::ArenaRunner::Error) { expect(it.rule).to eq(:statement_canceled) }
    end

    it "counts QUAACK's own timeout as no difference, and still judges the rest" do
      conn.exec("SET LOCAL statement_timeout = 300")
      expect(run([slow, "SELECT d.t.id FROM d.t WHERE true"], 300)).to eq([1])
    end
  end
end
