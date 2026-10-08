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
      ddl = "CREATE TABLE fx.bookings (id integer PRIMARY KEY, room integer NOT NULL, during int4range NOT NULL, " \
            "status text NOT NULL, EXCLUDE USING gist (room WITH =, during WITH &&))"
      sql = "SELECT b.id FROM fx.bookings b WHERE b.status = 'open' AND b.during && '[1,10)'"
      expect(outcomes(ddl, sql)).to all_ok
    end

    it "refuses the query up front when no element of the constraint is an equality" do
      ddl = "CREATE TABLE fx.slots (id integer PRIMARY KEY, during int4range NOT NULL, status text NOT NULL, " \
            "EXCLUDE USING gist (during WITH &&))"
      expect { outcomes(ddl, "SELECT s.id FROM fx.slots s WHERE s.status = 'open'") }
        .to raise_error(described_class::Error) { expect(it.rule).to eq(:exclusion_constraint) }
    end
  end
end
