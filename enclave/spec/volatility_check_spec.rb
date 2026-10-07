# frozen_string_literal: true

require "quaack/enclave/volatility_check"
require_relative "support/catalog_shadow"

# Every example runs against real Postgres, since whether a function is
# volatile is in the production catalog. Each one gets a fresh copy of the
# sample schema, plus schemas a and b for the functions, operators, and
# types it creates.
RSpec.describe Quaack::Enclave::VolatilityCheck do
  let(:conn) { test_database.connection }

  before do
    conn.exec("CREATE SCHEMA a")
    conn.exec("CREATE SCHEMA b")
  end

  def check(sql, settings = nil) = described_class.check(sql, settings, conn)

  def path(search_path) = { "search_path" => search_path }

  def volatile_error(detail, function: nil)
    raise_error(described_class::Error, "volatile_function: #{detail}") do |error|
      expect(error.rule).to eq("volatile_function")
      expect(error.function).to eq(function) if function
    end
  end

  # A SQL function. volatility is VOLATILE, STABLE, or IMMUTABLE.
  def function(signature, volatility, returns: "int", body: "SELECT 1")
    conn.exec("CREATE FUNCTION #{signature} RETURNS #{returns} LANGUAGE sql #{volatility} AS $$#{body}$$")
  end

  describe "a query whose functions are all stable or immutable" do
    # The built-ins a typical query uses. None of their overloads is
    # volatile, so the conservative resolution doesn't abort on them.
    let(:sql) do
      <<~SQL
        SELECT o.id + 1, o.status || 'x', to_char(o.created_at, 'YYYY'), date_trunc('day', o.created_at),
               coalesce(c.name, ''), nullif(c.name, ''), greatest(o.id, 2), o.created_at::date, lower(c.email),
               count(*) OVER (PARTITION BY o.status), now(), CURRENT_TIMESTAMP, CURRENT_DATE, LOCALTIMESTAMP,
               CURRENT_USER, extract(year FROM o.created_at), o.created_at AT TIME ZONE 'UTC',
               date '2020-01-01', interval '1 day', CAST(o.total_cents AS numeric(10, 2)),
               CASE o.status WHEN 'x' THEN 1 ELSE 2 END, o.status::text, -o.total_cents
        FROM orders o
        JOIN customers c ON c.id = o.customer_id
        JOIN LATERAL (SELECT max(id) AS m FROM orders WHERE customer_id = c.id) l ON true
        WHERE o.status IN ('a', 'b') AND o.total_cents BETWEEN 1 AND 10 AND c.email LIKE '%x'
          AND c.email NOT ILIKE 'y%' AND o.status IS DISTINCT FROM 'z' AND o.id = ANY ('{1,2}'::bigint[])
          AND o.customer_id IN (SELECT id FROM customers) AND o.created_at > now() - interval '1 day'
        ORDER BY o.created_at DESC
        LIMIT 10
      SQL
    end

    it "passes, and is a query Postgres runs" do
      expect(conn.exec(sql).nfields).to eq(23)
      expect(check(sql)).to be_nil
    end

    it "passes with aggregates, set-returning functions, and set operations" do
      sql = <<~SQL
        SELECT status, sum(total_cents), avg(total_cents), string_agg(status, ',' ORDER BY id), array_agg(id)
        FROM orders GROUP BY status HAVING count(*) > 1
        UNION ALL
        SELECT 'x', g, g, 'y', ARRAY[g::bigint] FROM generate_series(1, 3) g, unnest(ARRAY[1]) u
      SQL

      expect(conn.exec(sql).nfields).to eq(5)
      expect(check(sql)).to be_nil
    end
  end

  describe "a volatile built-in" do
    it "aborts, naming the function and its schema" do
      expect { check("SELECT random()") }.to volatile_error("function pg_catalog.random is volatile",
                                                            function: "pg_catalog.random")
      expect { check("SELECT nextval('orders_id_seq')") }.to volatile_error("function pg_catalog.nextval is volatile")
      expect { check("SELECT clock_timestamp()") }
        .to volatile_error("function pg_catalog.clock_timestamp is volatile")
    end

    # random() in each place a query can call a function.
    {
      "the select list" => "SELECT id, random() FROM orders",
      "WHERE" => "SELECT id FROM orders WHERE total_cents > random()",
      "JOIN ON" => "SELECT 1 FROM orders o JOIN customers c ON c.id = o.customer_id AND random() > 0.5",
      "GROUP BY" => "SELECT count(*) FROM orders GROUP BY random() > 0.5",
      "HAVING" => "SELECT status FROM orders GROUP BY status HAVING count(*) > random()",
      "ORDER BY" => "SELECT id FROM orders ORDER BY random()",
      "DISTINCT ON" => "SELECT DISTINCT ON (random() > 0.5) id FROM orders",
      "a window's PARTITION BY" => "SELECT row_number() OVER (PARTITION BY random() > 0.5) FROM orders",
      "a named window" => "SELECT sum(id) OVER w FROM orders WINDOW w AS (ORDER BY random())",
      "LIMIT" => "SELECT id FROM orders LIMIT (random() * 10)::int",
      "OFFSET" => "SELECT id FROM orders OFFSET (random() * 10)::int",
      "a CTE" => "WITH r AS (SELECT random() AS x) SELECT x FROM r",
      "a subquery in FROM" => "SELECT * FROM (SELECT random()) s",
      "a scalar subquery" => "SELECT (SELECT random())",
      "an EXISTS subquery" => "SELECT 1 WHERE EXISTS (SELECT 1 WHERE random() > 0.5)",
      "LATERAL" => "SELECT * FROM orders o, LATERAL (SELECT random() + o.id) l",
      "a function in FROM" => "SELECT * FROM random() r",
      "ROWS FROM" => "SELECT * FROM ROWS FROM (random()) r",
      "a FROM function's argument" => "SELECT * FROM generate_series(1, (random() * 3)::int) g",
      "an aggregate's argument" => "SELECT sum(random()) FROM orders",
      "an aggregate's FILTER" => "SELECT count(*) FILTER (WHERE random() > 0.5) FROM orders",
      "an aggregate's ORDER BY" => "SELECT string_agg(status, ',' ORDER BY random()) FROM orders",
      "a UNION branch" => "SELECT 1 UNION SELECT random()",
      "VALUES" => "VALUES (random())",
      "another function's argument" => "SELECT round(abs(random()))",
      "CASE" => "SELECT CASE WHEN random() > 0.5 THEN 1 END",
      "COALESCE" => "SELECT coalesce(null, random())",
      "a cast's argument" => "SELECT random()::text",
      "an operator's argument" => "SELECT 1 + random()",
      "a row comparison's tuple" => "SELECT id FROM orders WHERE (status, id) < ('a', (random() * 9)::int)"
    }.each do |place, sql|
      it "aborts on one in #{place}" do
        expect { check(sql) }.to volatile_error("function pg_catalog.random is volatile")
      end
    end

    it "refuses TABLESAMPLE, which isn't on the supported list" do
      expect { check("SELECT id FROM orders TABLESAMPLE bernoulli (10) REPEATABLE (1)") }
        .to raise_error(Quaack::Enclave::SupportedSql::Error, "unsupported_construct: RangeTableSample")
    end
  end

  describe "a function the query's database defines" do
    it "aborts on a volatile one, and passes a stable or immutable one in the same place" do
      function("a.bump()", "VOLATILE")
      function("a.calm()", "STABLE")
      function("a.still()", "IMMUTABLE")

      expect { check("SELECT a.bump()") }.to volatile_error("function a.bump is volatile")
      expect(check("SELECT a.calm(), a.still()")).to be_nil
    end

    it "aborts on a volatile set-returning function in FROM" do
      function("a.rows()", "VOLATILE", returns: "SETOF int")
      function("a.calm_rows()", "STABLE", returns: "SETOF int")

      expect { check("SELECT * FROM a.rows() r") }.to volatile_error("function a.rows is volatile")
      expect(check("SELECT * FROM a.calm_rows() r")).to be_nil
    end

    it "matches a quoted, mixed-case name exactly" do
      function('a."Bump"()', "VOLATILE")
      function("a.bump()", "STABLE")

      expect { check('SELECT a."Bump"()') }.to volatile_error(%(function a."Bump" is volatile))
      expect(check("SELECT a.Bump()")).to be_nil
    end
  end

  describe "resolving an unqualified name" do
    before do
      function("a.f()", "VOLATILE")
      function("b.f()", "STABLE")
    end

    it "searches every schema in the plan's search path, not just the first match" do
      expect(check("SELECT f()", path("b"))).to be_nil
      expect { check("SELECT f()", path("a")) }.to volatile_error("function a.f is volatile")
      expect { check("SELECT f()", path("b, a")) }.to volatile_error("function a.f is volatile")
    end

    it "searches only the schema a qualified name gives" do
      expect(check("SELECT b.f()", path("a"))).to be_nil
    end

    it "takes the schema, not the database, from a name that gives both" do
      expect { check("SELECT b.a.f()", path("b")) }.to volatile_error("function a.f is volatile")
      expect(check("SELECT a.b.f()", path("a"))).to be_nil
    end

    it "names the volatile match in the earliest schema of the path" do
      function("a.g()", "VOLATILE")
      function("b.g()", "VOLATILE")

      expect { check("SELECT g()", path("b, a")) }.to volatile_error("function b.g is volatile")
      expect { check("SELECT g()", path("a, b")) }.to volatile_error("function a.g is volatile")
    end

    it "searches pg_catalog even when the path doesn't list it" do
      expect { check("SELECT random()", path("b")) }.to volatile_error("function pg_catalog.random is volatile")
    end

    it "uses the default path, \"$user\" then public, when Settings has none" do
      function("public.g()", "VOLATILE")
      # The harness connects as postgres, so this is the $user schema.
      conn.exec("CREATE SCHEMA postgres")
      function("postgres.h()", "VOLATILE")

      expect { check("SELECT g()", nil) }.to volatile_error("function public.g is volatile")
      expect { check("SELECT h()", {}) }.to volatile_error("function postgres.h is volatile")
      expect(check("SELECT f()", nil)).to be_nil
    end

    it "raises on a search path it can't read" do
      expect { check("SELECT f()", path('"a')) }
        .to raise_error(described_class::Error, /\Abad_search_path: search_path "a has an unterminated quote\z/)
    end
  end

  describe "overloads" do
    it "counts the call's arguments, and only aborts on an overload that could take that many" do
      function("a.f()", "STABLE")
      function("a.f(int)", "VOLATILE")

      expect(check("SELECT a.f()")).to be_nil
      expect { check("SELECT a.f(1)") }.to volatile_error("function a.f is volatile")
      expect(check("SELECT a.f(1, 2)")).to be_nil
    end

    it "counts arguments that have defaults" do
      function("a.f(x int, y int DEFAULT 0)", "VOLATILE")

      expect { check("SELECT a.f(1)") }.to volatile_error("function a.f is volatile")
      expect { check("SELECT a.f(1, 2)") }.to volatile_error("function a.f is volatile")
      expect(check("SELECT a.f()")).to be_nil
      expect(check("SELECT a.f(1, 2, 3)")).to be_nil
    end

    it "counts a variadic function's extra arguments" do
      function("a.f(x int, VARIADIC rest int[])", "VOLATILE")

      expect { check("SELECT a.f(1, 2, 3, 4)") }.to volatile_error("function a.f is volatile")
      expect { check("SELECT a.f(1, VARIADIC ARRAY[2])") }.to volatile_error("function a.f is volatile")
    end

    it "needs at least one argument for a variadic parameter, as Postgres does" do
      function("a.f(x int, VARIADIC rest int[])", "VOLATILE")

      expect { conn.exec("SELECT a.f(1)") }.to raise_error(PG::UndefinedFunction)
      expect(check("SELECT a.f(1)")).to be_nil
      expect { check("SELECT a.f(1, 2)") }.to volatile_error("function a.f is volatile")
    end

    it "lets a variadic parameter's default stand in for its arguments" do
      function("a.f(x int, VARIADIC rest int[] DEFAULT '{}')", "VOLATILE")

      expect(conn.exec("SELECT a.f(1)").getvalue(0, 0)).to eq("1")
      expect { check("SELECT a.f(1)") }.to volatile_error("function a.f is volatile")
      expect(check("SELECT a.f()")).to be_nil
    end

    it "counts named arguments" do
      function("a.f(x int, y int)", "VOLATILE")

      expect { check("SELECT a.f(y => 1, x => 2)") }.to volatile_error("function a.f is volatile")
    end
  end

  describe "an aggregate" do
    before do
      function("a.step(s int, x int)", "VOLATILE", body: "SELECT s + x")
      function("a.calm_step(s int, x int)", "IMMUTABLE", body: "SELECT s + x")
      conn.exec("CREATE AGGREGATE a.shaky(int) (SFUNC = a.step, STYPE = int, INITCOND = '0')")
      conn.exec("CREATE AGGREGATE a.steady(int) (SFUNC = a.calm_step, STYPE = int, INITCOND = '0')")
    end

    it "aborts when a function it calls is volatile, naming both" do
      expect { check("SELECT a.shaky(total_cents) FROM orders") }
        .to volatile_error("function a.shaky calls volatile function a.step", function: "a.step")
      expect(check("SELECT a.steady(total_cents) FROM orders")).to be_nil
    end

    it "doesn't count an ordinary aggregate's ORDER BY as arguments" do
      expect { check("SELECT a.shaky(total_cents ORDER BY id, status) FROM orders") }
        .to volatile_error("function a.shaky calls volatile function a.step")
    end

    it "aborts when it's used as a window function" do
      expect { check("SELECT a.shaky(total_cents) OVER () FROM orders") }
        .to volatile_error("function a.shaky calls volatile function a.step")
    end

    it "checks its final function too" do
      function("a.finish(s int)", "VOLATILE", body: "SELECT s")
      conn.exec("CREATE AGGREGATE a.late(int) (SFUNC = a.calm_step, STYPE = int, FINALFUNC = a.finish)")

      expect { check("SELECT a.late(total_cents) FROM orders") }
        .to volatile_error("function a.late calls volatile function a.finish")
    end

    it "checks its combine function" do
      function("a.combine(s int, t int)", "VOLATILE", body: "SELECT s + t")
      conn.exec("CREATE AGGREGATE a.merged(int) (SFUNC = a.calm_step, STYPE = int, COMBINEFUNC = a.combine)")

      expect { check("SELECT a.merged(total_cents) FROM orders") }
        .to volatile_error("function a.merged calls volatile function a.combine")
    end

    # A serial function takes internal, which only C functions can, so
    # these borrow avg(numeric)'s with LANGUAGE internal, which needs the
    # harness's superuser.
    {
      "serial" => ["SERIALFUNC", "numeric_avg_serialize", "(internal)", "bytea"],
      "deserial" => ["DESERIALFUNC", "numeric_avg_deserialize", "(bytea, internal)", "internal"]
    }.each do |kind, (option, borrowed, args, returns)|
      it "checks its #{kind} function" do
        functions = { "SERIALFUNC" => "pg_catalog.numeric_avg_serialize",
                      "DESERIALFUNC" => "pg_catalog.numeric_avg_deserialize" }
        conn.exec("CREATE FUNCTION a.shaky_#{kind}#{args} RETURNS #{returns} LANGUAGE internal VOLATILE " \
                  "STRICT AS '#{borrowed}'")
        functions[option] = "a.shaky_#{kind}"
        conn.exec(<<~SQL)
          CREATE AGGREGATE a.avg_#{kind}(numeric) (
            SFUNC = pg_catalog.numeric_avg_accum, STYPE = internal, FINALFUNC = pg_catalog.numeric_avg,
            COMBINEFUNC = pg_catalog.numeric_avg_combine,
            SERIALFUNC = #{functions["SERIALFUNC"]}, DESERIALFUNC = #{functions["DESERIALFUNC"]})
        SQL

        expect { check("SELECT a.avg_#{kind}(total_cents) FROM orders") }
          .to volatile_error("function a.avg_#{kind} calls volatile function a.shaky_#{kind}")
      end
    end

    # The moving-aggregate functions run when it's a window function over
    # a moving frame.
    {
      "forward transition" => ["a.step", "a.calm_step", nil],
      "inverse transition" => ["a.calm_step", "a.step", nil],
      "final" => ["a.calm_step", "a.calm_step", "a.finish"]
    }.each do |kind, (forward, inverse, final)|
      it "checks its moving-aggregate #{kind} function" do
        function("a.finish(s int)", "VOLATILE", body: "SELECT s")
        mfinal = final ? ", MFINALFUNC = #{final}" : ""
        conn.exec(<<~SQL)
          CREATE AGGREGATE a.moving(int) (
            SFUNC = a.calm_step, STYPE = int, INITCOND = '0',
            MSFUNC = #{forward}, MINVFUNC = #{inverse}, MSTYPE = int, MINITCOND = '0'#{mfinal})
        SQL

        called = [forward, inverse, final].find { |f| f && f != "a.calm_step" }
        expect { check("SELECT a.moving(total_cents) OVER (ROWS 2 PRECEDING) FROM orders") }
          .to volatile_error("function a.moving calls volatile function #{called}")
      end
    end

    # An ordered-set aggregate's pronargs counts its direct arguments and
    # its WITHIN GROUP ones. Its final function takes internal, so it
    # borrows percentile_disc's with LANGUAGE internal.
    it "counts an ordered-set aggregate's WITHIN GROUP arguments" do
      conn.exec("CREATE FUNCTION a.shaky_final(internal, float8, anyelement) RETURNS anyelement " \
                "LANGUAGE internal VOLATILE AS 'percentile_disc_final'")
      conn.exec(<<~SQL)
        CREATE AGGREGATE a.pct(float8 ORDER BY anyelement) (
          SFUNC = pg_catalog.ordered_set_transition, STYPE = internal,
          FINALFUNC = a.shaky_final, FINALFUNC_EXTRA)
      SQL
      sql = "SELECT a.pct(0.5) WITHIN GROUP (ORDER BY id) FROM orders"

      expect(conn.exec(sql).ntuples).to eq(1)
      expect { check(sql) }.to volatile_error("function a.pct calls volatile function a.shaky_final")
    end

    it "counts a hypothetical-set aggregate's WITHIN GROUP arguments" do
      # Not variadic, so its pronargs, 2, matches only when the WITHIN GROUP
      # argument counts.
      conn.exec("CREATE FUNCTION a.shaky_rank(internal, bigint, bigint) RETURNS bigint " \
                "LANGUAGE internal VOLATILE AS 'hypothetical_rank_final'")
      conn.exec(<<~SQL)
        CREATE AGGREGATE a.hrank(bigint ORDER BY bigint) (
          SFUNC = pg_catalog.ordered_set_transition_multi, STYPE = internal,
          FINALFUNC = a.shaky_rank, FINALFUNC_EXTRA, HYPOTHETICAL)
      SQL
      sql = "SELECT a.hrank(3) WITHIN GROUP (ORDER BY id) FROM orders"
      fixture = conn.exec("SELECT provariadic::int, pronargs FROM pg_proc WHERE oid = 'a.hrank'::regproc").values

      expect(fixture).to eq([%w[0 2]])

      expect(conn.exec(sql).ntuples).to eq(1)
      expect { check(sql) }.to volatile_error("function a.hrank calls volatile function a.shaky_rank")
    end
  end

  describe "an operator" do
    # An operator named symbol in schema, over two ints (or just a
    # right-hand int, for a prefix operator).
    def operator(symbol, volatility, prefix: false, schema: "a")
      name = "op_#{symbol.unpack1("H*")}_#{prefix ? "l" : "b"}_#{volatility.downcase}"
      args = prefix ? "y int" : "x int, y int"
      function("#{schema}.#{name}(#{args})", volatility, returns: "boolean", body: "SELECT true")
      sides = prefix ? "RIGHTARG = int" : "LEFTARG = int, RIGHTARG = int"
      conn.exec("CREATE OPERATOR #{schema}.#{symbol} (#{sides}, FUNCTION = #{schema}.#{name})")
      name
    end

    it "aborts when its function is volatile, naming both" do
      name = operator("%%%", "VOLATILE")

      expect { check("SELECT 1 %%% 2", path("a")) }
        .to volatile_error("operator a.%%% calls volatile function a.#{name}")
    end

    it "passes when its function is stable or immutable" do
      operator("%%%", "STABLE")
      operator("&&&", "IMMUTABLE")

      expect(check("SELECT 1 %%% 2, 1 &&& 2", path("a"))).to be_nil
    end

    it "resolves OPERATOR(schema.op) in that schema only" do
      name = operator("%%%", "VOLATILE")

      expect { check("SELECT 1 OPERATOR(a.%%%) 2") }
        .to volatile_error("operator a.%%% calls volatile function a.#{name}")
      expect(check("SELECT 1 OPERATOR(b.%%%) 2", path("a"))).to be_nil
    end

    it "names the volatile match in the earliest schema of the path" do
      name = operator("%%%", "VOLATILE")
      operator("%%%", "VOLATILE", schema: "b")

      expect { check("SELECT 1 %%% 2", path("b, a")) }
        .to volatile_error("operator b.%%% calls volatile function b.#{name}")
      expect { check("SELECT 1 %%% 2", path("a, b")) }
        .to volatile_error("operator a.%%% calls volatile function a.#{name}")
    end

    it "tells a prefix operator from a binary one" do
      binary = operator("###", "VOLATILE")
      operator("###", "STABLE", prefix: true)

      expect(check("SELECT ### 1", path("a"))).to be_nil
      expect { check("SELECT 1 ### 1", path("a")) }
        .to volatile_error("operator a.### calls volatile function a.#{binary}")
    end

    it "aborts on a volatile prefix operator" do
      name = operator("!!!", "VOLATILE", prefix: true)

      expect { check("SELECT !!! 1", path("a")) }
        .to volatile_error("operator a.!!! calls volatile function a.#{name}")
    end

    # Syntax that calls an operator it doesn't spell out. Each needs only
    # the operator given, so a volatile one of that name in schema a trips
    # it when the path includes a, and nothing does when it doesn't.
    {
      "IN (list)" => ["=", "SELECT 1 WHERE 1 IN (1, 2)"],
      "NOT IN (list)" => ["<>", "SELECT 1 WHERE 1 NOT IN (1, 2)"],
      "= ANY (array)" => ["=", "SELECT 1 WHERE 1 = ANY (ARRAY[1, 2])"],
      "< ALL (array)" => ["<", "SELECT 1 WHERE 1 < ALL (ARRAY[1, 2])"],
      "IN (subquery)" => ["=", "SELECT 1 WHERE 1 IN (SELECT 1)"],
      "= ANY (subquery)" => ["=", "SELECT 1 WHERE 1 = ANY (SELECT 1)"],
      "> ALL (subquery)" => [">", "SELECT 1 WHERE 1 > ALL (SELECT 1)"],
      "BETWEEN's lower bound" => [">=", "SELECT 1 WHERE 1 BETWEEN 0 AND 2"],
      "BETWEEN's upper bound" => ["<=", "SELECT 1 WHERE 1 BETWEEN 0 AND 2"],
      "BETWEEN SYMMETRIC" => ["<=", "SELECT 1 WHERE 1 BETWEEN SYMMETRIC 2 AND 0"],
      "NOT BETWEEN's lower bound" => ["<", "SELECT 1 WHERE 1 NOT BETWEEN 2 AND 3"],
      "NOT BETWEEN's upper bound" => [">", "SELECT 1 WHERE 1 NOT BETWEEN 2 AND 3"],
      "IS DISTINCT FROM" => ["=", "SELECT 1 WHERE 1 IS DISTINCT FROM 2"],
      "IS NOT DISTINCT FROM" => ["=", "SELECT 1 WHERE 1 IS NOT DISTINCT FROM 2"],
      "NULLIF" => ["=", "SELECT nullif(1, 2)"],
      "a simple CASE" => ["=", "SELECT CASE 1 WHEN 2 THEN 3 END"],
      "JOIN USING" => ["=", "SELECT * FROM (SELECT 1 AS k) x JOIN (SELECT 1 AS k) y USING (k)"],
      "NATURAL JOIN" => ["=", "SELECT * FROM (SELECT 1 AS k) x NATURAL JOIN (SELECT 1 AS k) y"],
      "ORDER BY USING" => ["<", "SELECT k FROM (SELECT 1 AS k) x ORDER BY k USING <"]
    }.each do |syntax, (op, sql)|
      it "aborts on #{syntax}, which calls #{op}" do
        name = operator(op, "VOLATILE")

        expect(check(sql, path("b"))).to be_nil
        expect { check(sql, path("a")) }.to volatile_error("operator a.#{op} calls volatile function a.#{name}")
      end
    end

    it "doesn't count = for a searched CASE or a join with ON" do
      name = operator("=", "VOLATILE")

      expect(check("SELECT CASE WHEN true THEN 1 END", path("a"))).to be_nil
      expect(check("SELECT * FROM (SELECT 1 AS k) x JOIN (SELECT 1 AS j) y ON true", path("a"))).to be_nil
      expect { check("SELECT CASE 1 WHEN 2 THEN 3 END", path("a")) }
        .to volatile_error("operator a.= calls volatile function a.#{name}")
    end

    {
      "LIKE" => ["~~", "SELECT 'x' LIKE 'y'"],
      "NOT LIKE" => ["!~~", "SELECT 'x' NOT LIKE 'y'"],
      "ILIKE" => ["~~*", "SELECT 'x' ILIKE 'y'"]
    }.each do |syntax, (op, sql)|
      it "aborts on #{syntax}, which calls #{op}" do
        function("a.op_text(x text, y text)", "VOLATILE", returns: "boolean", body: "SELECT true")
        conn.exec("CREATE OPERATOR a.#{op} (LEFTARG = text, RIGHTARG = text, FUNCTION = a.op_text)")

        expect(check(sql, path("b"))).to be_nil
        expect { check(sql, path("a")) }.to volatile_error("operator a.#{op} calls volatile function a.op_text")
      end
    end
  end

  describe "a cast" do
    # a.pair and a.calm_pair are composite types. A cast from int to each
    # calls a volatile and a stable function.
    before do
      conn.exec("CREATE TYPE a.pair AS (x int)")
      conn.exec("CREATE TYPE a.calm_pair AS (x int)")
      function("a.to_pair(int)", "VOLATILE", returns: "a.pair", body: "SELECT ROW($1)::a.pair")
      function("a.to_calm_pair(int)", "STABLE", returns: "a.calm_pair", body: "SELECT ROW($1)::a.calm_pair")
      conn.exec("CREATE CAST (int AS a.pair) WITH FUNCTION a.to_pair(int)")
      conn.exec("CREATE CAST (int AS a.calm_pair) WITH FUNCTION a.to_calm_pair(int)")
    end

    it "aborts when its function is volatile, naming both" do
      expect { check("SELECT 1::a.pair") }.to volatile_error("cast to a.pair calls volatile function a.to_pair")
      expect { check("SELECT CAST(1 AS a.pair)") }
        .to volatile_error("cast to a.pair calls volatile function a.to_pair")
    end

    it "passes when its function is stable" do
      expect(check("SELECT 1::a.calm_pair")).to be_nil
    end

    it "resolves an unqualified type name through the search path" do
      expect(check("SELECT 1::pair", path("b"))).to be_nil
      expect { check("SELECT 1::pair", path("a")) }
        .to volatile_error("cast to a.pair calls volatile function a.to_pair")
    end

    it "names the volatile match in the earliest schema of the path" do
      conn.exec("CREATE TYPE b.pair AS (x int)")
      function("b.to_pair(int)", "VOLATILE", returns: "b.pair", body: "SELECT ROW($1)::b.pair")
      conn.exec("CREATE CAST (int AS b.pair) WITH FUNCTION b.to_pair(int)")

      expect { check("SELECT 1::pair", path("b, a")) }
        .to volatile_error("cast to b.pair calls volatile function b.to_pair")
      expect { check("SELECT 1::pair", path("a, b")) }
        .to volatile_error("cast to a.pair calls volatile function a.to_pair")
    end

    it "aborts on a cast to an array of the type" do
      expect { check("SELECT ARRAY[1]::a.pair[]") }
        .to volatile_error("cast to a.pair calls volatile function a.to_pair")
    end

    it "aborts on a cast whose target is the type's array type" do
      conn.exec("CREATE TYPE a.box AS (x int)")
      function("a.to_boxes(int)", "VOLATILE", returns: "a.box[]", body: "SELECT ARRAY[ROW($1)::a.box]")
      conn.exec("CREATE CAST (int AS a.box[]) WITH FUNCTION a.to_boxes(int)")

      expect(conn.exec("SELECT (1::a.box[])[1]").getvalue(0, 0)).to eq("(1)")
      expect { check("SELECT 1::a.box[]") }.to volatile_error("cast to a.box calls volatile function a.to_boxes")
    end

    it "aborts on a cast to a domain over the type, or a domain over that" do
      conn.exec("CREATE DOMAIN a.pair_d AS a.pair")
      conn.exec("CREATE DOMAIN a.pair_dd AS a.pair_d")

      expect { check("SELECT 1::a.pair_dd") }.to volatile_error("cast to a.pair_dd calls volatile function a.to_pair")
    end

    it "doesn't take a call with two arguments for a cast" do
      expect(check("SELECT a.pair(1, 2)")).to be_nil
    end

    it "aborts on a cast to a domain whose CHECK calls a volatile function" do
      function("a.valid(int)", "VOLATILE", returns: "boolean", body: "SELECT true")
      function("a.calm_valid(int)", "STABLE", returns: "boolean", body: "SELECT true")
      conn.exec("CREATE DOMAIN a.checked AS int CHECK (a.valid(VALUE))")
      conn.exec("CREATE DOMAIN a.calm_checked AS int CHECK (a.calm_valid(VALUE))")

      expect { check("SELECT 1::a.checked") }.to volatile_error("cast to a.checked calls volatile function a.valid")
      expect(check("SELECT 1::a.calm_checked")).to be_nil
    end

    it "aborts on a function-style cast" do
      expect { check("SELECT a.pair(1)") }.to volatile_error("cast to a.pair calls volatile function a.to_pair")
      expect(check("SELECT a.calm_pair(1)")).to be_nil
    end

    # A cast from an unknown literal, such as 'x'::a.loud, calls the type's
    # input function, and so does a cast through text. Postgres builds an
    # input function only in C, so a.loud borrows text's with LANGUAGE
    # internal, which needs the harness's superuser.
    it "aborts when the type's input function is volatile" do
      conn.exec("CREATE TYPE a.loud")
      conn.exec("CREATE FUNCTION a.loud_in(cstring) RETURNS a.loud LANGUAGE internal VOLATILE AS 'textin'")
      conn.exec("CREATE FUNCTION a.loud_out(a.loud) RETURNS cstring LANGUAGE internal IMMUTABLE AS 'textout'")
      conn.exec("CREATE TYPE a.loud (INPUT = a.loud_in, OUTPUT = a.loud_out, LIKE = text)")

      expect(conn.exec("SELECT 'x'::a.loud::text").getvalue(0, 0)).to eq("x")
      expect { check("SELECT 'x'::a.loud") }.to volatile_error("cast to a.loud calls volatile function a.loud_in")
    end
  end

  # t.f calls the function f on t's row, when t has no column f.
  # Task 20260930-14: the session's search_path puts public ahead of
  # pg_catalog, and public's comparisons say no (see CatalogShadow), so an
  # unqualified one would find no volatile function anywhere.
  describe "a catalog read when public's comparison operators shadow pg_catalog's" do
    before do
      function("a.bump()", "VOLATILE")
      function("a.bumpo(public.orders)", "VOLATILE")
      conn.exec("CREATE TYPE a.pair AS (x int)")
      function("a.to_pair(int)", "VOLATILE", returns: "a.pair", body: "SELECT ROW($1)::a.pair")
      conn.exec("CREATE CAST (int AS a.pair) WITH FUNCTION a.to_pair(int)")
      function("a.op_volatile(x int, y int)", "VOLATILE", returns: "boolean", body: "SELECT true")
      conn.exec("CREATE OPERATOR a.%%% (LEFTARG = int, RIGHTARG = int, FUNCTION = a.op_volatile)")
      conn.exec("SET search_path = public, pg_catalog")
      CatalogShadow.plant(conn, :operators)
    end

    it "still aborts on a volatile function, operator, attribute, and cast" do
      expect { check("SELECT a.bump()") }.to volatile_error("function a.bump is volatile")
      expect { check("SELECT 1 %%% 2", path("a")) }
        .to volatile_error("operator a.%%% calls volatile function a.op_volatile")
      expect { check("SELECT 1::a.pair") }.to volatile_error("cast to a.pair calls volatile function a.to_pair")
      expect { check("SELECT o.bumpo FROM orders o", path("a")) }.to volatile_error("function a.bumpo is volatile")
    end
  end

  describe "attribute notation" do
    before do
      function("public.bumpo(public.orders)", "VOLATILE")
      function("public.calmo(public.orders)", "STABLE")
      function("a.status(int)", "VOLATILE")
    end

    it "aborts when it calls a volatile function on the row" do
      sql = "SELECT o.bumpo FROM orders o"

      expect(conn.exec(sql).nfields).to eq(1)
      expect { check(sql) }.to volatile_error("function public.bumpo is volatile")
      expect { check("SELECT public.orders.bumpo FROM public.orders") }
        .to volatile_error("function public.bumpo is volatile")
    end

    it "passes a stable one, and a column whose name a function takes only a plain value" do
      expect(check("SELECT o.calmo FROM orders o")).to be_nil
      expect(check("SELECT o.status FROM orders o", path("a, public"))).to be_nil
    end

    # pg_catalog.system and bernoulli are volatile, but take internal,
    # which a row can never be passed as.
    it "passes a column named like a volatile built-in that can't take a row" do
      expect(check("SELECT o.system, o.bernoulli, o.array_shuffle FROM orders o")).to be_nil
    end
  end

  describe "a rewrite candidate" do
    it "is checked the same way, $n placeholders and all" do
      clean = "SELECT id FROM public.orders WHERE customer_id = $1 AND created_at > $2::timestamptz LIMIT $3"
      volatile = "SELECT id FROM public.orders WHERE customer_id = $1 AND random() < $2"

      expect(check(clean)).to be_nil
      expect { check(volatile) }.to volatile_error("function pg_catalog.random is volatile")
    end
  end

  describe "SQL outside the supported list" do
    # Each would pass without the check.
    {
      "ROW" => ["SELECT ROW(1, 2)", "RowExpr"],
      "a row comparison with a subquery" => ["SELECT 1 WHERE (1, 2) < (SELECT 1, 2)", "RowExpr"],
      "SIMILAR TO" => ["SELECT 'x' SIMILAR TO 'y'", "A_Expr AEXPR_SIMILAR"],
      "an UPDATE" => ["UPDATE orders SET status = 'x'", "UpdateStmt"]
    }.each do |construct, (sql, detail)|
      it "refuses #{construct} before reading the catalog" do
        expect { described_class.check(sql, nil, nil) }
          .to raise_error(Quaack::Enclave::SupportedSql::Error, "unsupported_construct: #{detail}")
      end
    end
  end

  describe "the error" do
    let(:sentinel) { "QUAACK_SENTINEL_5c1e" }

    # Postgres's quote_ident: quoted only when it has to be, with "" for a
    # quote, so a name with dots, commas, or quotes still reads one way.
    it "quotes each name the way Postgres would" do
      odd = conn.quote_ident('we,ird"{x}')
      conn.exec("CREATE SCHEMA #{odd}")
      function(%(#{odd}."f{""}"()), "VOLATILE")
      function('a."select"()', "VOLATILE")
      function(%(#{odd}.op(x int, y int)), "VOLATILE", returns: "boolean", body: "SELECT true")
      conn.exec("CREATE OPERATOR #{odd}.%%% (LEFTARG = int, RIGHTARG = int, FUNCTION = #{odd}.op)")
      conn.exec('CREATE TYPE a."Pair" AS (x int)')
      function('a."To Pair"(int)', "VOLATILE", returns: 'a."Pair"', body: 'SELECT ROW($1)::a."Pair"')
      conn.exec('CREATE CAST (int AS a."Pair") WITH FUNCTION a."To Pair"(int)')

      expect { check(%(SELECT #{odd}."f{""}"())) }.to volatile_error(%(function "we,ird""{x}"."f{""}" is volatile))
      expect { check('SELECT a."select"()') }.to volatile_error(%(function a."select" is volatile))
      expect { check("SELECT 1 OPERATOR(#{odd}.%%%) 2") }
        .to volatile_error(%(operator "we,ird""{x}".%%% calls volatile function "we,ird""{x}".op))
      expect { check('SELECT 1::a."Pair"') }.to volatile_error(%(cast to a."Pair" calls volatile function a."To Pair"))
    end

    it "quotes the operator's function, and the cast's type schema and function schema" do
      odd = conn.quote_ident('we,ird"{x}')
      conn.exec("CREATE SCHEMA #{odd}")
      function(%(#{odd}."Op Fn"(x int, y int)), "VOLATILE", returns: "boolean", body: "SELECT true")
      conn.exec(%(CREATE OPERATOR a.%%% (LEFTARG = int, RIGHTARG = int, FUNCTION = #{odd}."Op Fn")))
      conn.exec("CREATE TYPE #{odd}.duo AS (x int)")
      function("#{odd}.to_duo(int)", "VOLATILE", returns: "#{odd}.duo", body: "SELECT ROW($1)::#{odd}.duo")
      conn.exec("CREATE CAST (int AS #{odd}.duo) WITH FUNCTION #{odd}.to_duo(int)")

      expect { check("SELECT 1 OPERATOR(a.%%%) 2") }
        .to volatile_error(%(operator a.%%% calls volatile function "we,ird""{x}"."Op Fn"))
      expect { check("SELECT 1::#{odd}.duo") }
        .to volatile_error(%(cast to "we,ird""{x}".duo calls volatile function "we,ird""{x}".to_duo))
    end

    it "never quotes the query's literals" do
      function("a.bump(text)", "VOLATILE")
      errors = [
        "SELECT a.bump('#{sentinel}')",
        "SELECT random() FROM orders WHERE status = '#{sentinel}'",
        "SELECT '#{sentinel}' '#{sentinel}'",
        "SELECT * FROM orders WHERE status = '#{sentinel}' AND"
      ].map do |sql|
        check(sql)
        nil
      rescue described_class::Error => e
        e
      end

      expect(errors).to all(be_a(described_class::Error))
      errors.each do |error|
        expect(error.message).not_to include(sentinel)
        expect(error.full_message).not_to include(sentinel)
        expect(error.cause).to be_nil
      end
    end

    it "replaces a parse error, naming only the rule" do
      expect { check("SELECT '#{sentinel}' '#{sentinel}'") }
        .to raise_error(described_class::Error, "parse_error: the query doesn't parse #{PARSER_NOTE}") { |e|
          expect(e.rule).to eq("parse_error")
        }
    end
  end
end
