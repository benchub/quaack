# frozen_string_literal: true

require "json"
require "quaack/enclave/clock_anchoring"
require "quaack/enclave/redaction"

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

  # Postgres names a column or FROM function that has no alias after the
  # function it calls, and anchoring must not change that name.
  describe "the names Postgres makes up" do
    before { stand_in("SELECT pg_catalog.now()") }

    # The original and the anchored query, run in one transaction, so
    # now() and the stand-in agree.
    def both(sql)
      anchored = anchor(sql).sql
      conn.exec("BEGIN")
      [conn.exec(sql), conn.exec(anchored)]
    ensure
      conn.exec("COMMIT")
    end

    [
      "SELECT now(), now()::date, now()::text, CURRENT_DATE, CURRENT_DATE::text, LOCALTIMESTAMP, localtime(2), " \
      "current_timestamp(1), transaction_timestamp(), now() + interval '1 day', " \
      "CASE WHEN true THEN NULL ELSE now() END, CASE WHEN true THEN now() END, now()::date::text, " \
      "CURRENT_DATE::text COLLATE \"C\", (now())::date, now() IS NULL, coalesce(now(), now())",
      "SELECT (SELECT now()), (SELECT CURRENT_DATE UNION SELECT CURRENT_DATE), ARRAY(SELECT now()), " \
      "EXISTS (SELECT now()), (SELECT (SELECT LOCALTIME))",
      "SELECT * FROM now()", "SELECT * FROM now() WITH ORDINALITY", "SELECT * FROM pg_catalog.now() AS t",
      "SELECT * FROM (SELECT now(), CURRENT_DATE) s", "WITH w AS (SELECT LOCALTIMESTAMP) SELECT * FROM w"
    ].each do |sql|
      it "keeps every column name of #{sql[0, 60]}..." do
        original, anchored = both(sql)
        expect(anchored.fields).to eq(original.fields)
        expect(anchored.values).to eq(original.values)
      end
    end

    [
      ["SELECT s.now FROM (SELECT now()) s", 1],
      ["WITH w AS (SELECT now()) SELECT w.now FROM w", 1],
      ["SELECT now() ORDER BY now", 1],
      ["SELECT s.current_date FROM (SELECT CURRENT_DATE) s", 1],
      ["SELECT s.localtimestamp FROM (SELECT LOCALTIMESTAMP) s", 1],
      ["SELECT now.now FROM now()", 1],
      ["SELECT x.now FROM (SELECT (SELECT now())) x", 1]
    ].each do |sql, rows|
      it "still finds the name in #{sql}" do
        original, anchored = both(sql)
        expect(anchored.values).to eq(original.values)
        expect(anchored.ntuples).to eq(rows)
      end
    end

    # A table column named now would take over ORDER BY now or GROUP BY
    # now, if the output column were no longer named now.
    context "with a table that has a column named now" do
      before do
        conn.exec("CREATE TABLE public.ev (id int, now int)")
        conn.exec("INSERT INTO public.ev VALUES (1, 1), (2, 2)")
      end

      it "orders by the output column, not the table's" do
        %w[now()::date now() CURRENT_DATE].each do |expression|
          name = expression == "CURRENT_DATE" ? %("current_date") : "now"
          sql = "SELECT id, #{expression} FROM public.ev ORDER BY #{name}, id DESC"
          original, anchored = both(sql)
          expect(anchored.column_values(0)).to eq(%w[2 1])
          expect(anchored.values).to eq(original.values)
        end
      end

      # GROUP BY looks for a table's column first, so it groups by ev.now
      # either way.
      it "groups by the table's column, as the original does" do
        original, anchored = both("SELECT now()::date, count(*) FROM public.ev GROUP BY now")
        expect(anchored.column_values(1)).to eq(%w[1 1])
        expect(anchored.values).to eq(original.values)
      end
    end

    it "groups by the output column when no table has a column of that name" do
      %w[now() now()::date CURRENT_DATE].each do |expression|
        name = expression == "CURRENT_DATE" ? %("current_date") : "now"
        original, anchored = both("SELECT #{expression}, count(*) FROM public.customers GROUP BY #{name}")
        expect(anchored.column_values(1)).to eq(["2000"])
        expect(anchored.values).to eq(original.values)
      end
    end
  end

  # 20260926-48: 'now', 'today', 'yesterday', and 'tomorrow', after 3g has
  # made them placeholders, must anchor to what Postgres reads them as.
  describe "the clock-reading literals" do
    before do
      stand_in("SELECT pg_catalog.now()")
      conn.exec("SET TimeZone = 'Pacific/Chatham'")
    end

    let(:statistics) do
      { "tables" => [{ "schema" => "public", "name" => "orders",
                       "column_names" => %w[id customer_id status total_cents created_at],
                       "clock_columns" => { "created_at" => "timestamptz" } }] }
    end

    # The original's rows and the anchored query's, bound with the slow
    # literals, in one transaction so now() and the stand-in agree.
    def both(sql)
      anchored, bound = anchor_and_bind(sql)
      conn.exec("BEGIN")
      bound.prepare(conn, "quaack_q")
      [anchored, conn.exec(sql).values, bound.execute(conn, "quaack_q").values]
    ensure
      conn.exec("COMMIT")
      conn.exec("DEALLOCATE ALL")
    end

    def anchor_and_bind(sql)
      redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))
      anchored = described_class.anchor(redacted.sql, nil, placeholder_map: redacted.placeholder_map, statistics:)
      [anchored, Quaack::Enclave::Redaction.binding(anchored.sql, redacted.placeholder_map)]
    end

    it "gives each word's value as a date, timestamp, and timestamptz" do
      casts = %w[now today yesterday tomorrow].product(%w[date timestamp timestamptz timestamp(0)])
                                              .map { |word, type| "'#{word}'::#{type}" } +
              ["' Today '::date", "timestamp 'TOMORROW'", "'now'::time", "'now'::timetz"]
      anchored, original, bound = both("SELECT #{casts.join(", ")}")
      expect(anchored.replacements.length).to eq(casts.length)
      expect(bound).to eq(original)
    end

    it "reads the anchor, not the clock" do
      stand_in("SELECT '2026-03-17 03:04:05+00'::timestamptz")
      conn.exec("SET TimeZone = 'America/Los_Angeles'")
      _, _, bound = both("SELECT 'yesterday'::date, 'today'::timestamp, 'tomorrow'::timestamptz, 'now'::timestamptz")
      expect(bound).to eq([["2026-03-15", "2026-03-16 00:00:00", "2026-03-17 00:00:00-07", "2026-03-16 20:04:05-07"]])
    end

    it "anchors a word compared with a timestamptz column" do
      conn.exec("INSERT INTO orders (customer_id, status, total_cents, created_at) " \
                "SELECT 1, 'anchor', 1, now() - interval '1 hour'")
      sql = "SELECT count(*) FROM public.orders o WHERE o.created_at >= 'yesterday' AND o.created_at < 'tomorrow' " \
            "AND o.status = 'anchor'"
      anchored, original, bound = both(sql)
      expect(anchored.replacements.map(&:original)).to eq(%w[$1 $2])
      expect([bound, original]).to eq([[["1"]], [["1"]]])
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
