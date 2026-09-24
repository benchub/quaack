# frozen_string_literal: true

require "json"
require "pg_query"
require "tmpdir"
require "quaack/enclave/redaction"
require "quaack/enclave/store"

# 3g against real plans from the test harness's Postgres: the production
# plan from EXPLAIN (ANALYZE, VERBOSE, BUFFERS, SETTINGS), and a racetrack
# plan from a plain EXPLAIN.
REDACTION_PRODUCTION = "EXPLAIN (ANALYZE, VERBOSE, BUFFERS, SETTINGS, FORMAT JSON)"
REDACTION_RACETRACK = "EXPLAIN (FORMAT JSON)"

RSpec.describe Quaack::Enclave::Redaction do
  let(:production) { REDACTION_PRODUCTION }
  let(:racetrack) { REDACTION_RACETRACK }

  def explain(query, how, settings: [])
    conn = test_database.connection
    conn.transaction do
      settings.each { |s| conn.exec("SET LOCAL #{s}") }
      JSON.parse(conn.exec("#{how} #{query}").getvalue(0, 0))
    end
  end

  def redact(query, settings: [])
    described_class.redact(PgQuery.parse(query), explain(query, production, settings:))
  end

  def rows(sql) = test_database.connection.exec(sql).values

  # Sentinels in every place a literal can sit: the select list, a join
  # qual, LIKE, an IN list, a number, ORDER BY and GROUP BY expressions,
  # HAVING, a window's run condition, an InitPlan, and a function's
  # arguments.
  sentinel_queries = {
    "a join, LIKE, an IN list, and ORDER BY" =>
      "SELECT o.id, 'quaack-sentinel-select'::text AS tag, o.total_cents + 918273601 AS bumped " \
      "FROM public.orders o JOIN public.customers c ON c.id = o.customer_id AND c.name <> 'quaack-sentinel-join' " \
      "WHERE o.status LIKE 'quaack-sentinel-like%' OR o.status IN ('quaack-sentinel-in-1', 'quaack-sentinel-in-2') " \
      "OR o.total_cents = 918273602 ORDER BY o.status = 'quaack-sentinel-order', o.id",
    "GROUP BY and HAVING" =>
      "SELECT o.status || 'quaack-sentinel-group', count(*) FROM public.orders o " \
      "GROUP BY o.status || 'quaack-sentinel-group' HAVING count(*) > 918273603",
    "a window, an InitPlan, and a function" =>
      "SELECT s.id FROM (SELECT o.id, row_number() OVER (ORDER BY o.id) AS n FROM public.orders o " \
      "WHERE o.customer_id = (SELECT c.id FROM public.customers c WHERE c.email = 'quaack-sentinel-init') " \
      "OR substr(o.status, 918273604) = 'quaack-sentinel-substr') s WHERE s.n < 918273605"
  }

  def sentinels(query) = query.scan(/quaack-sentinel-[a-z0-9-]+|9182736\d\d/).uniq

  def leaked(data, sentinels) = sentinels.select { |s| JSON.generate(data, max_nesting: false).include?(s) }

  sentinel_queries.each do |what, query|
    it "leaves no literal in the redacted query, plan, or shapes of #{what}" do
      result = redact(query)
      sentinels = sentinels(query)
      expect(leaked(explain(query, production), sentinels)).not_to be_empty
      expect(leaked([result.query.sql, result.plan.explain, result.placeholder_shapes], sentinels)).to be_empty
      expect(leaked(result.placeholder_map, sentinels)).to eq(sentinels)
      expect(leaked([result.inspect, result.to_s], sentinels)).to be_empty
      expect(result.plan.masked).to eq(0)
    end
  end

  it "catches a sentinel planted in what it checks, so the check itself works" do
    query = sentinel_queries.values.first
    result = redact(query)
    planted = JSON.parse(JSON.generate(result.plan.explain))
    planted.first["Plan"]["Alias"] = "quaack-sentinel-join"
    expect(leaked(planted, sentinels(query))).to eq(["quaack-sentinel-join"])
  end

  it "matches a number written with a point and no digits after it" do
    query = "SELECT o.id FROM public.orders o WHERE o.status = '918273.e5' OR o.total_cents::numeric = 918273.e5"
    result = redact(query, settings: ["enable_indexscan = off", "enable_bitmapscan = off"])
    expect(result.plan.explain.first["Plan"]["Filter"])
      .to eq("((o.status = $1::text) OR ((o.total_cents)::numeric = $2::numeric))")
    expect(result.plan.masked).to eq(0)
  end

  it "masks a timestamp Postgres printed in its own format, and finds no consumer for it" do
    result = redact("SELECT o.id FROM public.orders o WHERE o.created_at > '2031-07-19'",
                    settings: ["enable_indexscan = off", "enable_bitmapscan = off"])
    expect(result.plan.explain.first["Plan"]["Filter"]).to eq("(o.created_at > $?::timestamp with time zone)")
    expect(result.plan.masked).to eq(1)
    expect(result.placeholder_shapes["$1"]["rows"]).to eq("status" => "none")
  end

  describe "bit strings" do
    let(:query) { "SELECT t.id FROM public.bits t WHERE t.b = B'10110' AND t.x = X'1F'" }

    before do
      conn = test_database.connection
      conn.exec("CREATE TABLE public.bits (id int, b bit varying, x bit(8))")
      conn.exec("INSERT INTO public.bits VALUES (1, B'10110', X'1F'), (2, B'1', X'00')")
      conn.exec("ANALYZE public.bits")
    end

    it "matches the bits Postgres prints to the placeholders that hold them" do
      result = redact(query)
      expect(result.plan.explain.first["Plan"]["Filter"]).to eq("((t.b = $1::bit varying) AND (t.x = $2::\"bit\"))")
      expect(result.plan.masked).to eq(0)
      expect(result.placeholder_shapes.values.map { it["rows"]["status"] }).to eq(%w[found found])
    end

    it "binds them to the same rows" do
      result = redact(query)
      bound = described_class.binding(result.query.sql, result.placeholder_map)
      conn = test_database.connection
      bound.prepare(conn, "quaack_bits")
      expect(bound.execute(conn, "quaack_bits").values).to eq([["1"]])
    ensure
      conn&.exec("DEALLOCATE ALL")
    end
  end

  describe "row counts" do
    let(:seq_scan) { ["enable_indexscan = off", "enable_bitmapscan = off"] }

    it "annotates each placeholder with the estimated and actual rows of the node whose qual holds it" do
      query = "SELECT o.id FROM public.orders o WHERE o.status = 'shipped' AND o.total_cents < 5000 LIMIT 3"
      result = redact(query, settings: seq_scan)
      scan = result.plan.explain.first["Plan"]["Plans"].first
      expect(scan["Node Type"]).to eq("Seq Scan")
      found = { "status" => "found", "node" => "Seq Scan", "qual" => "Filter", "estimated_rows" => scan["Plan Rows"],
                "actual_rows" => scan["Actual Rows"], "actual_loops" => scan["Actual Loops"] }
      expect(result.placeholder_shapes.transform_values { it["rows"] })
        .to eq("$1" => found, "$2" => found, "$3" => { "status" => "none" })
      expect(scan["Plan Rows"]).to be > 3
    end

    it "takes a bitmap scan's rows from its index scan, not the heap scan's recheck" do
      result = redact("SELECT c.id FROM public.customers c WHERE c.email = 'a' OR c.email = 'b'")
      expect(result.plan.explain.first["Plan"]["Node Type"]).to eq("Bitmap Heap Scan")
      expect(result.placeholder_shapes.values.map { it["rows"].slice("status", "node", "qual") })
        .to eq([{ "status" => "found", "node" => "Bitmap Index Scan", "qual" => "Index Cond" }] * 2)
    end

    it "gives two placeholders with one value the rows of the node they share" do
      result = redact("SELECT o.id FROM public.orders o WHERE o.total_cents > 5 AND o.customer_id <> 5",
                      settings: seq_scan)
      expect(result.placeholder_shapes.values.map { it["rows"]["status"] }).to eq(%w[found found])
    end

    it "counts one node once, when two of its quals hold the value" do
      result = redact("SELECT o.id FROM public.orders o WHERE o.id = 5 AND o.customer_id = 5",
                      settings: ["enable_bitmapscan = off"])
      node = result.plan.explain.first["Plan"]
      expect(node.slice("Index Cond",
                        "Filter")).to eq("Index Cond" => "(o.id = $1)", "Filter" => "(o.customer_id = $1)")
      expect(result.placeholder_shapes.values.map { it["rows"].slice("status", "qual") })
        .to eq([{ "status" => "found", "qual" => "Index Cond" }] * 2)
    end

    it "gives the loops of a node that ran more than once" do
      query = "SELECT o.id FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
              "WHERE c.id < 20 AND o.status = 'shipped'"
      result = redact(query, settings: ["enable_hashjoin = off", "enable_mergejoin = off", "enable_memoize = off",
                                        "enable_bitmapscan = off"])
      inner = result.plan.explain.first["Plan"]["Plans"].last
      expect(inner["Actual Loops"]).to be > 1
      expect(result.placeholder_shapes["$2"]["rows"])
        .to include("node" => inner["Node Type"], "actual_loops" => inner["Actual Loops"],
                    "actual_rows" => inner["Actual Rows"])
    end

    it "annotates a shared placeholder from the one qual that holds it, wherever else it's written" do
      query = "SELECT o.status || '-x', count(*) FROM public.orders o GROUP BY o.status || '-x' " \
              "HAVING (o.status || '-x') <> 'x'"
      result = redact(query)
      plan = JSON.generate(result.plan.explain)
      expect(plan).to include('"Group Key":["(o.status || $1::text)"]', "((o.status || $1::text) <> $2::text)")
      expect(result.placeholder_shapes["$1"]["rows"]).to include("status" => "found", "qual" => "Filter")
      expect(result.plan.masked).to eq(0)
    end

    it "calls it ambiguous when a value is in more than one node" do
      query = "SELECT o.id FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
              "WHERE o.customer_id = 5 AND c.id = 5"
      result = redact(query)
      expect(JSON.generate(result.plan.explain)).to include('"Index Cond":"(c.id = $1)"', "(o.customer_id = $1)")
      expect(result.placeholder_shapes.values.map { it["rows"] }).to eq([{ "status" => "ambiguous" }] * 2)
    end
  end

  describe "racetrack plans" do
    let(:query) { "SELECT o.id FROM public.orders o WHERE o.status = 'quaack-sentinel-race' AND o.total_cents < 5000" }

    it "redacts a plan without actual rows against the same placeholder map" do
      result = redact(query)
      racetrack_plan = described_class.plan(explain(query, racetrack), result.placeholder_map)
      node = racetrack_plan.explain.first["Plan"]
      expect(JSON.generate(racetrack_plan.explain)).not_to include("quaack-sentinel-race")
      expect([node["Filter"], node["Index Cond"]].compact.join).to include("$1::text", "$2")
      expect(node).not_to have_key("Actual Rows")
      expect(racetrack_plan.masked).to eq(0)
    end

    it "masks a literal the placeholder map doesn't hold, and counts it" do
      map = redact(query).placeholder_map
      other = described_class.plan(explain(query.sub("quaack-sentinel-race", "quaack-sentinel-else"), racetrack), map)
      expect(JSON.generate(other.explain)).not_to include("quaack-sentinel")
      expect(other.masked).to eq(1)
    end
  end

  describe "the governed store" do
    around { |example| Dir.mktmpdir { |dir| @base = dir and example.run } }

    it "keeps the value map and the shapes as two entries, and reads the map back" do
      result = redact("SELECT o.id FROM public.orders o WHERE o.status = 'quaack-sentinel-store'")
      store = Quaack::Enclave::Store.create(base: @base)
      result.store(store)
      expect(store.read("placeholder_map")).to eq("$1" => { "value" => "quaack-sentinel-store", "type" => "unknown" })
      expect(store.read("placeholder_shapes")).to eq(result.placeholder_shapes)
      expect(JSON.generate(store.read("placeholder_shapes"))).not_to include("quaack-sentinel")
      expect(described_class.placeholder_map(store)).to eq(result.placeholder_map)
    end

    it "refuses a stored map that isn't one, without quoting it" do
      store = Quaack::Enclave::Store.create(base: @base)
      store.write("placeholder_map", { "$1" => "quaack-sentinel-bad" })
      expect { described_class.placeholder_map(store) }
        .to raise_error(described_class::Error, "bad_placeholder_map")
    end
  end

  describe "binding with PREPARE" do
    queries = [
      "SELECT o.id, o.total_cents / 7 AS part, 'x' AS tag FROM public.orders o " \
      "WHERE o.status LIKE 'ship%' AND o.total_cents BETWEEN 1000 AND 1.5e4 ORDER BY 1 LIMIT 20",
      "SELECT o.status, count(*) FROM public.orders o WHERE o.id IN (1, 2, 3, 40) OR o.customer_id = -5 " \
      "GROUP BY 1 ORDER BY 1",
      "SELECT c.name FROM public.customers c WHERE c.created_at > DATE '2025-01-03' AND c.name IS NOT NULL " \
      "ORDER BY c.name OFFSET 2 LIMIT 5",
      "SELECT o.id, NULL AS nothing, coalesce(NULL, o.status) FROM public.orders o WHERE o.id < 4 ORDER BY o.id",
      # Untyped strings that Postgres types as text only because nothing
      # else types them, and bit strings.
      "SELECT concat('a', o.status) FROM public.orders o WHERE o.id < 4 ORDER BY o.id",
      "SELECT jsonb_build_object('k', o.id) FROM public.orders o WHERE o.id < 4 ORDER BY o.id",
      "SELECT NULL IS NULL, B'101' | B'010', coalesce('a', 'b')",
      "SELECT g FROM generate_series(1, 5) g, unnest(ARRAY['a']) u, LATERAL generate_series(g, 7) h ORDER BY 1",
      "SELECT count(*) FROM public.orders o",
      "SELECT concat('a', 'b')",
      "SELECT o.id FROM public.orders o WHERE o.status <> 'x' AND o.id < '9' ORDER BY 1"
    ]

    def run(binding, name = "quaack_3g")
      conn = test_database.connection
      binding.prepare(conn, name)
      binding.execute(conn, name).values
    ensure
      conn.exec("DEALLOCATE ALL")
    end

    queries.each do |query|
      it "returns the original's rows for the redacted query: #{query[0, 60]}" do
        result = redact(query)
        expect(result.query.sql).not_to include("'")
        original = rows(query)
        expect(original).not_to be_empty
        expect(run(described_class.binding(result.query.sql, result.placeholder_map))).to eq(original)
      end
    end

    [
      "SELECT date_trunc('day', o.created_at), count(*) FROM public.orders o " \
      "GROUP BY date_trunc('day', o.created_at) HAVING count(*) > 1 ORDER BY date_trunc('day', o.created_at)",
      "SELECT o.status || '-x', count(*) FROM public.orders o GROUP BY o.status || '-x' " \
      "HAVING (o.status || '-x') <> 'x' ORDER BY o.status || '-x'",
      "SELECT DISTINCT ON (o.status || 'a') o.id FROM public.orders o ORDER BY o.status || 'a', o.id",
      "SELECT DISTINCT o.status || 'a' FROM public.orders o ORDER BY o.status || 'a'",
      "SELECT string_agg(DISTINCT o.status || 'a', ',' ORDER BY o.status || 'a') FROM public.orders o",
      "SELECT rank() OVER (ORDER BY o.status || 'a') FROM public.orders o GROUP BY o.status || 'a' ORDER BY 1",
      # The GROUP BY and HAVING sentinel query, which returns no rows.
      "SELECT o.status || 'quaack-sentinel-group', count(*) FROM public.orders o " \
      "GROUP BY o.status || 'quaack-sentinel-group' HAVING count(*) > 918273603"
    ].each do |query|
      it "binds expressions Postgres requires to match, with the original's rows: #{query[0, 60]}" do
        result = redact(query)
        expect(run(described_class.binding(result.query.sql, result.placeholder_map))).to eq(rows(query))
      end
    end

    it "types each number the way Postgres types the literal" do
      literals = %w[2147483647 2147483648 9223372036854775807 9223372036854775808 -9223372036854775808
                    -9223372036854775809 1_000_000_000_000 0x7FFFFFFFFFFFFFFF 0x8000000000000000 1.5 5000000000] +
                 ["#{"0" * 90}5000000000"]
      literals.each do |literal|
        map = described_class.query(PgQuery.parse("SELECT #{literal}")).placeholder_map
        expect(map["$1"]["type"]).to eq(rows("SELECT pg_typeof(#{literal})::text").first.first), literal
      end
    end

    it "binds a rewrite candidate that leaves out one of the placeholders" do
      result = redact("SELECT o.id FROM public.orders o WHERE o.id = 5 AND o.status = 'shipped'")
      candidate = "SELECT o.id FROM public.orders o WHERE o.id = $1"
      bound = described_class.binding(candidate, result.placeholder_map)
      expect(bound.types).to eq(%w[integer text])
      expect(run(bound)).to eq(rows("SELECT o.id FROM public.orders o WHERE o.id = 5"))
    end

    it "types an untyped placeholder as text only where Postgres can't type it, inside a transaction too" do
      query = "SELECT concat('x', max(o.status)) FROM public.orders o WHERE o.status = 'shipped'"
      result = redact(query)
      bound = described_class.binding(result.query.sql, result.placeholder_map)
      conn = test_database.connection
      conn.transaction do
        expect(bound.prepare(conn, "quaack_tx")).to eq(%w[text unknown])
        expect(bound.execute(conn, "quaack_tx").values).to eq(rows(query))
        expect { conn.exec("ROLLBACK TO SAVEPOINT quaack_prepare") }
          .to raise_error(PG::Error) { |e| expect(e.result.error_field(PG::PG_DIAG_SQLSTATE)).to eq("3B001") }
        conn.exec("ROLLBACK")
      end
    end

    it "fails where the literal fails, as a polymorphic function of an untyped string does" do
      result = described_class.query(PgQuery.parse("SELECT json_agg('x') FROM public.orders o"))
      bound = described_class.binding(result.sql, result.placeholder_map)
      expect { bound.prepare(test_database.connection, "quaack_poly") }
        .to raise_error(described_class::Error) { |e| expect([e.rule, e.sqlstate]).to eq(%w[prepare_failed 42804]) }
    end

    # The one difference: an untyped string that nothing types reads as
    # unknown, but a parameter must have a type, so it's text.
    it "binds an untyped string pg_typeof sees as text, where the literal is unknown" do
      result = redact("SELECT pg_typeof('a')")
      expect(run(described_class.binding(result.query.sql, result.placeholder_map))).to eq([["text"]])
      expect(rows("SELECT pg_typeof('a')")).to eq([["unknown"]])
    end

    it "refuses SQL that isn't one SELECT, or that names a placeholder the map doesn't hold" do
      map = redact("SELECT o.id FROM public.orders o WHERE o.id = 5").placeholder_map
      expect { described_class.binding("SELECT $1; DROP TABLE public.orders", map) }
        .to raise_error(described_class::Error, "not_one_select")
      expect { described_class.binding("SELECT $2", map) }.to raise_error(described_class::Error, "unknown_placeholder")
      expect { described_class.binding("DELETE FROM public.orders WHERE id = $1", map) }
        .to raise_error(described_class::Error, "not_one_select")
    end

    it "refuses what SupportedSql refuses, such as a data-modifying CTE or FOR UPDATE" do
      map = redact("SELECT o.id FROM public.orders o WHERE o.id = 5").placeholder_map
      ["WITH d AS (DELETE FROM public.orders WHERE id = $1 RETURNING id) SELECT id FROM d",
       "SELECT o.id FROM public.orders o WHERE o.id = $1 FOR UPDATE"].each do |sql|
        expect { described_class.binding(sql, map) }.to raise_error(described_class::Error, "unsupported_construct")
      end
    end

    it "refuses a statement name that isn't a lowercase word" do
      bound = described_class.binding("SELECT 1", {})
      expect { bound.prepare(test_database.connection, "q; DROP TABLE public.orders") }.to raise_error(ArgumentError)
    end

    it "raises an error with no value in it when Postgres refuses a value or the SQL" do
      map = { "$1" => { "value" => "quaack-sentinel-value", "type" => "integer" } }
      bound = described_class.binding("SELECT $1 + 1", map)
      conn = test_database.connection
      bound.prepare(conn, "quaack_bad")
      expect { bound.execute(conn, "quaack_bad") }.to raise_error(described_class::Error) { |e|
        expect([e.message, e.rule, e.sqlstate, e.cause.inspect].join).not_to include("quaack-sentinel")
        expect(e.rule).to eq("execute_failed")
        expect(e.sqlstate).to eq("22P02")
      }
      broken = described_class.binding("SELECT $1 + 'quaack-sentinel-sql'::integer", map)
      expect { broken.prepare(conn, "quaack_worse") }.to raise_error(described_class::Error) { |e|
        expect([e.message, e.cause.inspect].join).not_to include("quaack-sentinel")
        expect(e.rule).to eq("prepare_failed")
      }
    ensure
      conn&.exec("DEALLOCATE ALL")
    end

    it "keeps the values out of inspect and out of the PREPARE" do
      map = redact("SELECT o.id FROM public.orders o WHERE o.status = 'quaack-sentinel-bind'").placeholder_map
      bound = described_class.binding("SELECT o.id FROM public.orders o WHERE o.status = $1", map)
      expect([bound.inspect, bound.to_s, bound.prepare_sql("q", bound.types)].join).not_to include("quaack-sentinel")
    end
  end
end
