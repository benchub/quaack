# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "quaack/enclave/racetrack"
require "quaack/enclave/clock_anchoring"
require "quaack/enclave/intake"
require "quaack/enclave/store"
require_relative "support/catalog_shadow"

# DESIGN.md's racetrack-setup: the racetrack gets hypopg, the quaack schema, and
# quaack.clock_anchor(), which returns the run's clock anchor from clock-anchor.
RSpec.describe Quaack::Enclave::Racetrack do
  let(:base) { Dir.mktmpdir }
  let(:store) { Quaack::Enclave::Store.create(base:) }
  let(:conn) { racetrack_and_arena.racetrack.connection }
  let(:anchor) { "2026-09-23T22:15:00.123456Z" }

  after { FileUtils.rm_rf(base) }

  def setup_racetrack(stored = anchor)
    store.write("clock_anchor", stored)
    described_class.setup(store:, connection: conn)
  end

  def value(sql) = conn.exec(sql).getvalue(0, 0)

  def returned_anchor
    value(%(SELECT to_char(quaack.clock_anchor() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')))
  end

  def refusal
    setup_racetrack
    nil
  rescue described_class::Error => e
    e
  end

  it "makes quaack.clock_anchor() return the stored anchor, to the microsecond" do
    conn.exec("SET TimeZone = 'Asia/Kolkata'")
    setup_racetrack

    expect(returned_anchor).to eq(anchor)
  end

  it "stores an anchor intake wrote from a time with another zone" do
    setup_racetrack(Quaack::Enclave::Intake.clock_anchor("2026-09-23T15:15:00.5-07:00"))

    expect(returned_anchor).to eq("2026-09-23T22:15:00.500000Z")
  end

  it "creates the function clock-anchor's queries call, with now()'s planner attributes" do
    setup_racetrack
    function = conn.exec(<<~SQL).to_a
      SELECT p.pronargs, p.prorettype::regtype::text AS returns, p.provolatile, p.proparallel, p.procost
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'quaack' AND p.proname = 'clock_anchor'
    SQL
    now = conn.exec("SELECT proparallel, procost FROM pg_proc WHERE oid = 'pg_catalog.now()'::regprocedure").first

    expect(function).to eq([{ "pronargs" => "0", "returns" => "timestamp with time zone", "provolatile" => "s",
                              "proparallel" => now["proparallel"], "procost" => now["procost"] }])
  end

  # An inlined function would plan as a constant, which now() doesn't:
  # partitions would be pruned at plan time, not at executor startup.
  it "isn't inlined, so the planner sees a call, as it does for now()" do
    setup_racetrack
    plan = conn.exec("EXPLAIN SELECT id FROM orders WHERE created_at > quaack.clock_anchor()").column_values(0).join

    expect(plan).to include("clock_anchor()")
  end

  it "installs hypopg" do
    setup_racetrack

    expect(value("SELECT count(*) FROM pg_extension WHERE extname = 'hypopg'")).to eq("1")
  end

  # Task 20261007-30: the session's search_path is the plan's
  # (RunServer.connect), which can name only schemas the racetrack doesn't
  # have, and CREATE EXTENSION would then have nowhere to put hypopg.
  it "installs hypopg in the quaack schema, whatever the search_path, and can run twice with it there" do
    conn.exec("SET search_path = reporting")
    setup_racetrack
    setup_racetrack

    expect(value("SELECT extnamespace::regnamespace::text FROM pg_extension WHERE extname = 'hypopg'"))
      .to eq("quaack")
  end

  it "keeps hypopg where it is when the racetrack has it already" do
    conn.exec("CREATE EXTENSION hypopg WITH SCHEMA public; SET client_min_messages = warning")
    setup_racetrack

    expect(value("SELECT extnamespace::regnamespace::text FROM pg_extension WHERE extname = 'hypopg'"))
      .to eq("public")
  end

  it "runs a query clock-anchor anchored, which then sees the anchor's time" do
    setup_racetrack
    conn.exec("SET TimeZone = 'UTC'")
    sql = Quaack::Enclave::ClockAnchoring.anchor("SELECT now(), CURRENT_DATE, LOCALTIMESTAMP(0)", nil).sql

    expect(conn.exec(sql).values).to eq([["2026-09-23 22:15:00.123456+00", "2026-09-23", "2026-09-23 22:15:00"]])
  end

  it "can run twice" do
    setup_racetrack
    setup_racetrack

    expect([returned_anchor, value("SELECT count(*) FROM pg_proc WHERE proname = 'clock_anchor'")]).to eq([anchor, "1"])
  end

  it "accepts a quaack schema that's already there and empty" do
    conn.exec("CREATE SCHEMA quaack")
    setup_racetrack

    expect(returned_anchor).to eq(anchor)
  end

  describe "a quaack schema holding something else" do
    [
      "CREATE TABLE quaack.sentinel_table (id int)",
      "CREATE FUNCTION quaack.clock_anchor(integer) RETURNS timestamptz LANGUAGE sql AS 'SELECT now()'",
      "CREATE FUNCTION quaack.clock_anchor() RETURNS text LANGUAGE sql AS 'SELECT 1'",
      "CREATE TYPE quaack.sentinel_type AS (a int)"
    ].each do |foreign|
      it "is refused, and changes nothing: #{foreign}" do
        conn.exec("CREATE SCHEMA quaack")
        conn.exec(foreign)
        error = refusal

        expect([error&.rule, error&.message]).to eq(%w[racetrack_quaack_schema_foreign racetrack_quaack_schema_foreign])
        expect(value("SELECT count(*) FROM pg_extension WHERE extname = 'hypopg'")).to eq("0")
      end
    end

    # Task 20260930-14: public's comparisons, ahead of pg_catalog's on the
    # search_path, would find nothing foreign.
    it "is refused when public's comparison operators shadow pg_catalog's" do
      conn.exec("CREATE SCHEMA quaack")
      conn.exec("CREATE TABLE quaack.sentinel_table (id int)")
      conn.exec("SET search_path = public, pg_catalog")
      CatalogShadow.plant(conn, :operators)

      expect(refusal&.rule).to eq("racetrack_quaack_schema_foreign")
    end

    it "is refused when public's count, one short, shadows pg_catalog's" do
      conn.exec("CREATE SCHEMA quaack")
      conn.exec("CREATE TABLE quaack.sentinel_table (id int)")
      conn.exec("SET search_path = public, pg_catalog")
      conn.exec("CREATE AGGREGATE public.count(*) " \
                "(sfunc = pg_catalog.int8inc, stype = pg_catalog.int8, initcond = '-1')")

      expect(refusal&.rule).to eq("racetrack_quaack_schema_foreign")
    end
  end

  describe "a stored anchor that isn't one intake writes" do
    ["2026-09-23T22:15:00Z'::timestamptz; DROP TABLE orders; --", "2026-02-30T00:00:00.000000Z", 12, nil].each do |bad|
      it "is refused without quoting it: #{bad.inspect}" do
        store.write("clock_anchor", bad)
        error = begin
          described_class.setup(store:, connection: conn)
        rescue described_class::Error => e
          e
        end

        expect([error&.rule, error&.message]).to eq(%w[racetrack_bad_clock_anchor racetrack_bad_clock_anchor])
        expect(value("SELECT to_regprocedure('quaack.clock_anchor()')")).to be_nil
      end
    end
  end
end
