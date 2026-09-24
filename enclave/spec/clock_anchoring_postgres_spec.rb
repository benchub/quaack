# frozen_string_literal: true

require "json"
require "quaack/enclave/clock_anchoring"

# Each replacement has to keep the original's type, precision, and value,
# or the anchored query means something else. These run both on real
# Postgres. The test database gets a stand-in quaack.clock_anchor(), since
# creating the real one is 4a's and 4b's job.
RSpec.describe Quaack::Enclave::ClockAnchoring do
  let(:conn) { test_database.connection }

  def anchor(sql, settings = nil) = described_class.anchor(sql, settings)

  def stand_in(body)
    conn.exec("CREATE SCHEMA IF NOT EXISTS quaack")
    conn.exec("CREATE OR REPLACE FUNCTION quaack.clock_anchor() RETURNS timestamptz LANGUAGE sql STABLE " \
              "AS $$#{body}$$")
  end

  # The Settings hash from a real EXPLAIN (SETTINGS, FORMAT JSON), run with
  # search_path set to path.
  def settings_for(path)
    conn.exec("SET search_path = #{path}")
    JSON.parse(conn.exec("EXPLAIN (SETTINGS, FORMAT JSON) SELECT 1").getvalue(0, 0)).dig(0, "Settings")
  ensure
    conn.exec("RESET search_path")
  end

  let(:expressions) do
    [
      "now()", "pg_catalog.now()", "transaction_timestamp()", "statement_timestamp()", "CURRENT_TIMESTAMP",
      "current_timestamp(0)", "current_timestamp(3)", "CURRENT_DATE", "CURRENT_DATE + 1", "LOCALTIMESTAMP",
      "localtimestamp(2)", "LOCALTIME", "localtime(4)", "LOCALTIME + interval '1 hour'",
      "date_trunc('month', CURRENT_DATE)", "CURRENT_DATE - LOCALTIMESTAMP"
    ]
  end

  describe "with an anchor that is the transaction's own start time" do
    # With clock_anchor() returning now(), each anchored expression must
    # give exactly what the original gives, in a zone with an odd offset.
    before do
      stand_in("SELECT pg_catalog.now()")
      conn.exec("SET TimeZone = 'Pacific/Chatham'")
    end

    let(:sql) { "SELECT #{expressions.each_with_index.map { |e, i| "#{e} AS c#{i}" }.join(", ")}" }
    let(:result) { anchor(sql) }
    let(:columns) { expressions.each_index.map { |i| "c#{i}" } }

    # One statement, so statement_timestamp() is the transaction's start too.
    before do
      expect(result.replacements.length).to eq(expressions.length + 1)
      conn.exec("CREATE TEMP TABLE both_sides AS SELECT * FROM (#{sql}) o(#{columns.map { "o_#{it}" }.join(", ")}) " \
                "CROSS JOIN (#{result.sql}) a(#{columns.map { "a_#{it}" }.join(", ")})")
    end

    it "keeps each expression's type and precision" do
      types = conn.exec(<<~SQL).to_h { |row| [row["attname"], row["type"]] }
        SELECT attname, pg_catalog.format_type(atttypid, atttypmod) AS type
        FROM pg_catalog.pg_attribute WHERE attrelid = 'both_sides'::regclass AND attnum > 0
      SQL
      columns.each { |c| expect([c, types["a_#{c}"]]).to eq([c, types["o_#{c}"]]) }
      expect(types.values_at("o_c5", "o_c6", "o_c10", "o_c12"))
        .to eq(["timestamp(0) with time zone", "timestamp(3) with time zone", "timestamp(2) without time zone",
                "time(4) without time zone"])
    end

    it "keeps each expression's pg_typeof" do
      select = columns.map { |c| "pg_catalog.pg_typeof(o_#{c})::text, pg_catalog.pg_typeof(a_#{c})::text" }
      row = conn.exec("SELECT #{select.join(", ")} FROM both_sides").values.first
      row.each_slice(2).with_index do |(original, anchored), i|
        expect([expressions[i], anchored]).to eq([expressions[i], original])
      end
      expect(row.each_slice(2).map(&:first).uniq)
        .to contain_exactly("timestamp with time zone", "date", "timestamp without time zone",
                            "time without time zone", "interval")
    end

    it "keeps each expression's value" do
      same = columns.map { |c| "(o_#{c}::text IS NOT DISTINCT FROM a_#{c}::text)::text" }
      expect(conn.exec("SELECT #{same.join(", ")} FROM both_sides").values.first).to all(eq("true"))
    end
  end

  describe "with a fixed anchor, in a zone behind UTC" do
    before do
      stand_in("SELECT '2026-03-17 03:04:05.678951+00'::timestamptz")
      conn.exec("SET TimeZone = 'America/Los_Angeles'")
    end

    it "gives the session's local date and times at the anchor" do
      sql = "SELECT now(), statement_timestamp(), current_timestamp(2), CURRENT_DATE, LOCALTIMESTAMP, " \
            "localtimestamp(0), LOCALTIME, localtime(3)"
      expect(conn.exec(anchor(sql).sql).values.first).to eq(
        ["2026-03-16 20:04:05.678951-07", "2026-03-16 20:04:05.678951-07", "2026-03-16 20:04:05.68-07",
         "2026-03-16", "2026-03-16 20:04:05.678951", "2026-03-16 20:04:06", "20:04:05.678951", "20:04:05.679"]
      )
    end

    it "anchors every position in a query over real tables" do
      conn.exec("INSERT INTO customers (name, email, created_at) VALUES ('x', 'anchor@example.com', " \
                "'2026-03-16 12:00:00-07')")
      sql = <<~SQL
        WITH recent AS (SELECT id FROM public.customers WHERE created_at > now() - interval '1 day')
        SELECT c.email, (SELECT count(*) FROM recent WHERE recent.id = c.id), CURRENT_DATE - c.created_at::date,
               coalesce(NULL, LOCALTIMESTAMP)
        FROM public.customers c
        JOIN LATERAL (SELECT localtime(0) AS t) l ON true
        WHERE c.created_at BETWEEN CURRENT_TIMESTAMP - interval '1 day' AND pg_catalog.transaction_timestamp()
          AND EXISTS (SELECT 1 WHERE l.t > '19:00')
      SQL
      expect(conn.exec(anchor(sql).sql).values)
        .to eq([["anchor@example.com", "1", "0", "2026-03-16 20:04:05.678951"]])
    end
  end

  describe "a user function named now" do
    before do
      stand_in("SELECT '2026-03-17 03:04:05+00'::timestamptz")
      conn.exec("SET TimeZone = 'UTC'")
      conn.exec("CREATE FUNCTION public.now() RETURNS timestamptz LANGUAGE sql STABLE " \
                "AS $$SELECT '1999-01-01 00:00:00+00'::timestamptz$$")
    end

    it "loses to pg_catalog's on the default path, so the unqualified call is anchored and public's isn't" do
      expect(conn.exec("SELECT now() > '2000-01-01'").getvalue(0, 0)).to eq("t")
      settings = settings_for('"$user", public')
      expect(conn.exec(anchor("SELECT now(), public.now()", settings).sql).values.first)
        .to eq(["2026-03-17 03:04:05+00", "1999-01-01 00:00:00+00"])
    end

    it "wins when the path puts public before pg_catalog, so the unqualified call is refused" do
      settings = settings_for("public, pg_catalog")
      conn.exec("SET search_path = public, pg_catalog")
      expect(conn.exec("SELECT now()").getvalue(0, 0)).to eq("1999-01-01 00:00:00+00")
      expect { anchor("SELECT now()", settings) }.to raise_error(described_class::Error) { |error|
        expect(error.rule).to eq("clock_function_search_path")
      }
    ensure
      conn.exec("RESET search_path")
    end
  end
end
