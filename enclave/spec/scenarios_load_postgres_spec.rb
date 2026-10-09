# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"

# rewrite-test: scenarios on realistic schemas must load, or the query is
# refused up front with a rule, so no atom is silently left untested.
RSpec.describe Quaack::Enclave::Scenarios do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  def outcomes(ddl, sql)
    conn.exec("CREATE SCHEMA fx; #{ddl}")
    described_class.build(conn, PgQuery.parse(sql)).transform_values do |rows|
      runner.with_fixture(rows) { |tx| tx.query(sql) }
      :ok
    rescue Quaack::Enclave::ArenaRunner::Error => e
      [e.rule, e.sqlstate]
    end
  end

  def all_ok = eq(described_class::NAMES.to_h { [it, :ok] })

  def refused(ddl, sql)
    expect { outcomes(ddl, sql) }
      .to raise_error(described_class::Error) { expect(it.rule).to eq(:exclusion_constraint) }
  end

  it "gives boundary values to columns a generated column doesn't read" do
    conn.exec("CREATE SCHEMA fx; CREATE TABLE fx.items (id integer PRIMARY KEY, price integer NOT NULL, " \
              "qty integer NOT NULL, extra integer NOT NULL, " \
              "total integer GENERATED ALWAYS AS (price * qty) STORED, status text NOT NULL)")
    sql = "SELECT i.id FROM fx.items i WHERE i.status = 'open'"
    rows = described_class.build(conn, PgQuery.parse(sql))[:s5]
    values = ->(c) { rows.map { |r| r.values[r.columns.index(c)] } }
    bounds = %w[2147483647 -2147483648]
    expect(values.call("extra") & bounds).not_to be_empty
    expect((values.call("price") + values.call("qty")) & bounds).to be_empty
    expect(runner.with_fixture(rows) { |tx| tx.query(sql).rows.size }).to be >= 1
  end

  %w[STORED VIRTUAL].each do |kind|
    it "loads and runs every scenario on a table with a #{kind} generated column over integers" do
      ddl = "CREATE TABLE fx.items (id integer PRIMARY KEY, price integer NOT NULL, qty integer NOT NULL, " \
            "total integer GENERATED ALWAYS AS (price * qty) #{kind}, status text NOT NULL)"
      expect(outcomes(ddl, "SELECT i.id FROM fx.items i WHERE i.total > 50 AND i.status = 'open'")).to all_ok
    end
  end

  describe "with an exclusion constraint" do
    before { conn.exec("CREATE EXTENSION IF NOT EXISTS btree_gist") }

    it "loads every scenario when the constraint is an equality one" do
      ddl = "CREATE TABLE fx.rooms (id integer PRIMARY KEY, room integer NOT NULL, status text NOT NULL, " \
            "EXCLUDE USING gist (room WITH =))"
      expect(outcomes(ddl, "SELECT r.id FROM fx.rooms r WHERE r.status = 'open'")).to all_ok
    end

    it "loads every scenario for a booking table that excludes overlaps per room" do
      # Every row's during is the same default, so only room keeps them apart.
      ddl = "CREATE TABLE fx.bookings (id integer PRIMARY KEY, room integer NOT NULL, " \
            "during int4range NOT NULL DEFAULT '[1,10)', " \
            "status text NOT NULL, EXCLUDE USING gist (room WITH =, during WITH &&))"
      sql = "SELECT b.id FROM fx.bookings b WHERE b.status = 'open'"
      expect(outcomes(ddl, sql)).to all_ok
    end

    %w[int4range int8range numrange daterange tsrange tstzrange].each do |type|
      it "loads every scenario when a #{type} column excludes overlaps on its own" do
        ddl = "CREATE TABLE fx.slots (id integer PRIMARY KEY, during #{type} NOT NULL, status text NOT NULL, " \
              "EXCLUDE USING gist (during WITH &&))"
        expect(outcomes(ddl, "SELECT s.id FROM fx.slots s WHERE s.status = 'open'")).to all_ok
      end
    end

    it "refuses an overlap exclusion on a range type it can't step through" do
      ddl = "CREATE TYPE fx.textrange AS RANGE (subtype = text); " \
            "CREATE TABLE fx.slots (id integer PRIMARY KEY, during fx.textrange NOT NULL, status text NOT NULL, " \
            "EXCLUDE USING gist (during WITH &&))"
      refused(ddl, "SELECT s.id FROM fx.slots s WHERE s.status = 'open'")
    end

    it "refuses an overlap exclusion on a multirange" do
      ddl = "CREATE TABLE fx.slots (id integer PRIMARY KEY, during int4multirange NOT NULL, status text NOT NULL, " \
            "EXCLUDE USING gist (during WITH &&))"
      refused(ddl, "SELECT s.id FROM fx.slots s WHERE s.status = 'open'")
    end

    it "refuses an overlap exclusion with a WHERE predicate" do
      ddl = "CREATE TABLE fx.slots (id integer PRIMARY KEY, during int4range NOT NULL, status text NOT NULL, " \
            "EXCLUDE USING gist (during WITH &&) WHERE (status = 'open'))"
      refused(ddl, "SELECT s.id FROM fx.slots s WHERE s.status = 'open'")
    end

    it "refuses an exclusion with another operator" do
      ddl = "CREATE TABLE fx.slots (id integer PRIMARY KEY, during int4range NOT NULL, status text NOT NULL, " \
            "EXCLUDE USING gist (during WITH -|-))"
      refused(ddl, "SELECT s.id FROM fx.slots s WHERE s.status = 'open'")
    end

    it "refuses an overlap exclusion that also has another operator" do
      ddl = "CREATE TABLE fx.slots (id integer PRIMARY KEY, during int4range NOT NULL, spare int4range NOT NULL, " \
            "status text NOT NULL, EXCLUDE USING gist (during WITH &&, spare WITH -|-))"
      refused(ddl, "SELECT s.id FROM fx.slots s WHERE s.status = 'open'")
    end

    it "refuses an exclusion whose = isn't pg_catalog's btree equality" do
      ddl = <<~SQL
        CREATE OPERATOR fx.= (LEFTARG = integer, RIGHTARG = integer, FUNCTION = int4eq, COMMUTATOR = OPERATOR(fx.=));
        CREATE OPERATOR CLASS fx.fake_int4 FOR TYPE integer USING gist AS
          OPERATOR 3 fx.=, FUNCTION 1 gbt_int4_consistent, FUNCTION 2 gbt_int4_union,
          FUNCTION 3 gbt_int4_compress, FUNCTION 4 gbt_decompress, FUNCTION 5 gbt_int4_penalty,
          FUNCTION 6 gbt_int4_picksplit, FUNCTION 7 gbt_int4_same, STORAGE gbtreekey8;
        CREATE TABLE fx.rooms (id integer PRIMARY KEY, room integer NOT NULL, status text NOT NULL,
          EXCLUDE USING gist (room fx.fake_int4 WITH OPERATOR(fx.=)));
      SQL
      refused(ddl, "SELECT r.id FROM fx.rooms r WHERE r.status = 'open'")
    end
  end
end
