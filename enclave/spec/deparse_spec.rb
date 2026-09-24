# frozen_string_literal: true

require "quaack/enclave/deparse"
require "quaack/enclave/error_filter"

# The round-trip guard needs no database: it only parses and deparses. The
# specs that show what a changed query does against real Postgres are with
# its callers, in relation_qualifier_spec.rb and
# rewrite_candidate_check_spec.rb.
RSpec.describe Quaack::Enclave::Deparse do
  def tree(sql) = PgQuery.parse(sql).tree

  def where_of(sql) = tree("SELECT WHERE #{sql}").stmts[0].stmt.select_stmt.where_clause

  # The one fixed refusal, with no cause. The block, if any, gets it too.
  def refused(&also)
    raise_error(described_class::Error) do |error|
      expect([error.rule, error.message, error.cause])
        .to eq(["deparse_mismatch", "deparse_mismatch: pg_query's deparser changed the query, so it's refused", nil])
      also&.call(error)
    end
  end

  # The kind of SQL ORMs and reports send, including spellings the
  # deparser rewrites without changing the tree: != for <>, CAST for ::,
  # extra parentheses and whitespace, and lower-case keywords.
  common = [
    "SELECT * FROM public.users WHERE id = $1 LIMIT 1",
    'SELECT "users".* FROM "public"."users" WHERE "users"."email" = $1 LIMIT $2',
    "SELECT count(*) FROM public.orders WHERE created_at > now() - interval '1 day'",
    "SELECT * FROM public.t WHERE x IN ($1, $2, $3) ORDER BY y DESC NULLS LAST",
    "SELECT a, b FROM public.t WHERE a BETWEEN 1 AND 2 AND b NOT LIKE 'x%'",
    "select *   from public.t where (a is not null) and (b is true)",
    "SELECT t.* FROM public.t JOIN public.u ON u.id = t.u_id LEFT JOIN public.v USING (k) WHERE t.x = ANY($1)",
    "SELECT DISTINCT ON (a) a, b FROM public.t ORDER BY a, b",
    "SELECT a, sum(b) FILTER (WHERE c) OVER (PARTITION BY a ORDER BY d ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) " \
    "FROM public.t",
    "SELECT CASE WHEN a THEN 1 ELSE 2 END, coalesce(b, 0), nullif(c, '') FROM public.t",
    "SELECT * FROM public.t WHERE EXISTS (SELECT 1 FROM public.u WHERE u.id = t.id)",
    "SELECT id FROM public.t UNION SELECT id FROM public.u EXCEPT SELECT 3",
    "SELECT * FROM public.t WHERE a = 1 OR b = 2 AND NOT c",
    "SELECT * FROM public.t WHERE a != 1 AND b <> 2",
    "SELECT CAST(a AS integer), b::text, c::varchar(10), d::timestamp with time zone, e::numeric(10, 2) " \
    "FROM public.t",
    "SELECT -1, 1.5, 'x'::text, true, NULL, '{}'::int[] FROM public.t",
    "SELECT current_date, current_timestamp, localtime(3) FROM public.t",
    "SELECT * FROM public.t WHERE lower(email) ILIKE $1",
    "SELECT * FROM public.t, LATERAL (SELECT * FROM public.u WHERE u.t = t.id) s",
    "SELECT a FROM public.t GROUP BY a HAVING count(*) > 1 ORDER BY 1 FETCH FIRST 5 ROWS WITH TIES",
    "WITH recent AS MATERIALIZED (SELECT id FROM public.t WHERE id > $1) SELECT id FROM recent",
    "SELECT count(DISTINCT a ORDER BY a), percentile_cont(0.5) WITHIN GROUP (ORDER BY b) FROM public.t",
    "SELECT * FROM public.t WHERE a IN (SELECT b FROM public.u) AND c NOT IN (1, 2)",
    "SELECT j -> 'a', j ->> 'b', j @> '{}' FROM public.t WHERE x::date = current_date - 1",
    "SELECT row_number() OVER w, a[1:2], a[1] FROM public.t WINDOW w AS (ORDER BY a)",
    "SELECT * FROM public.t WHERE ((a = 1) AND ((b = 2) OR (c = 3)))"
  ].freeze

  # Each of pg_query's deparse bugs that 20260923-30 and 20260923-55 found.
  # The first changes the query's meaning. The rest deparse to SQL that
  # doesn't parse.
  repros = {
    "IS NOT DISTINCT FROM with AND" =>
      "SELECT * FROM public.t WHERE (status = $1) IS NOT DISTINCT FROM (true AND false)",
    "an ARRAY subquery's subscript" => "SELECT (ARRAY(SELECT 1))[1]",
    "an XMLTABLE PASSING cast" => "SELECT * FROM XMLTABLE('/a' PASSING CAST(x AS xml) COLUMNS a int)",
    "xmlexists" => "SELECT xmlexists('//a' PASSING BY REF (x::xml)) FROM public.t",
    "a typed CYCLE mark" =>
      "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) " \
      "CYCLE n SET is_cycle TO date '2020-01-01' DEFAULT date '2000-01-01' USING path SELECT * FROM r"
  }.freeze

  describe ".faithfully" do
    common.each do |sql|
      it "deparses #{sql}" do
        expect(described_class.faithfully(tree(sql))).to eq(PgQuery.deparse(tree(sql)))
      end
    end

    it "ignores locations, which never survive a deparse" do
      sql = "SELECT   a\n  FROM public.t   WHERE (b = 1)"
      expect(described_class.faithfully(tree(sql))).to eq("SELECT a FROM public.t WHERE b = 1")
    end

    it "ignores each statement's location and length" do
      sql = "  SELECT   1 ;   SELECT 2"
      expect(described_class.faithfully(tree(sql))).to eq("SELECT 1; SELECT 2")
    end

    # A JSON_TABLE path's name has a location of its own.
    it "ignores a JSON_TABLE path name's location" do
      sql = "SELECT * FROM JSON_TABLE(  j, '$'   AS p COLUMNS (a int PATH '$.a')) jt"
      expect(described_class.faithfully(tree(sql))).to eq(PgQuery.deparse(tree(sql)))
    end

    it "returns the SQL for a tree that was changed after parsing" do
      changed = tree("SELECT a FROM t")
      changed.stmts[0].stmt.select_stmt.from_clause[0].range_var.schemaname = "public"
      expect(described_class.faithfully(changed)).to eq("SELECT a FROM public.t")
    end

    repros.each do |name, sql|
      it "refuses #{name}" do
        expect { described_class.faithfully(tree(sql)) }.to refused
      end
    end

    it "shows the IS NOT DISTINCT FROM repro parses back as a different query" do
      deparsed = PgQuery.deparse(tree(repros.fetch("IS NOT DISTINCT FROM with AND")))
      expect(deparsed).to eq("SELECT * FROM public.t WHERE status = $1 IS NOT DISTINCT FROM true AND false")
      expect(PgQuery.parse(deparsed).tree.stmts[0].stmt.select_stmt.where_clause.node).to eq(:bool_expr)
    end

    # A fingerprint ignores constants, so it can't be what's compared.
    it "compares constants, not just structure" do
      changed = tree("SELECT 10")
      changed.stmts[0].stmt.select_stmt.target_list[0].res_target.val =
        PgQuery::Node.new(a_const: PgQuery::A_Const.new(fval: PgQuery::Float.new(fval: "10")))
      expect(PgQuery.deparse(changed)).to eq("SELECT 10")
      expect { described_class.faithfully(changed) }.to refused
    end

    # The parser cuts identifiers to 63 bytes, so a longer name in a built
    # tree comes back as a different name.
    it "refuses a name the parser would cut short" do
      changed = tree("SELECT a FROM public.t")
      changed.stmts[0].stmt.select_stmt.from_clause[0].range_var.relname = "t" * 64
      expect { described_class.faithfully(changed) }.to refused
    end

    it "doesn't change the tree it's given" do
      given = tree("SELECT a FROM public.t WHERE b = 1")
      before = given.to_proto
      described_class.faithfully(given)
      expect(given.to_proto).to eq(before)
    end
  end

  describe ".expression" do
    it "deparses an expression" do
      expect(described_class.expression(where_of("(status = 'open') AND (x != 1)")))
        .to eq("status = 'open' AND x <> 1")
    end

    it "refuses an expression that deparses as a different one" do
      expect { described_class.expression(where_of("(a = 1) IS NOT DISTINCT FROM (b AND c)")) }.to refused
    end

    # PgQuery.deparse_expr removes every "SELECT WHERE " it finds, even
    # inside a subquery.
    it "keeps a subquery that has only a WHERE" do
      node = where_of("EXISTS (SELECT WHERE x)")
      expect(PgQuery.deparse_expr(node)).to eq("EXISTS (x)")
      expect(described_class.expression(node)).to eq("EXISTS (SELECT WHERE x)")
    end
  end

  describe ".statement" do
    def index_stmt(sql) = tree(sql).stmts[0].stmt.index_stmt

    it "deparses a statement" do
      sql = "CREATE INDEX ON public.orders USING btree (a, b DESC NULLS LAST) INCLUDE (c) WHERE status = 'open'"
      expect(described_class.statement(index_stmt(sql))).to eq(sql)
    end

    it "refuses a statement that deparses as a different one" do
      stmt = index_stmt("CREATE INDEX ON public.orders (a)")
      stmt.index_params[0].index_elem.name = "a" * 64
      expect { described_class.statement(stmt) }.to refused
    end
  end

  describe "a sentinel in the query" do
    sentinel = "SENTINEL-7d2f0b"

    {
      "a mismatch" => "SELECT '#{sentinel}' AS \"#{sentinel}\" FROM public.t " \
                      "WHERE (status = '#{sentinel}') IS NOT DISTINCT FROM (true AND false)",
      "SQL that doesn't parse back" => "SELECT '#{sentinel}' AS \"#{sentinel}\", (ARRAY(SELECT '#{sentinel}'))[1]"
    }.each do |what, sql|
      it "never shows up in the error for #{what}" do
        expect(sql.scan(sentinel).size).to eq(3)
        error = nil
        expect { described_class.faithfully(tree(sql)) }.to(refused { |e| error = e })
        line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "1")
        expect(line).to eq('{"type":"error","step":"1","rule":"deparse_mismatch"}')
        expect([error.message, error.full_message, line]).to all(satisfy { |text| !text.include?(sentinel) })
      end
    end
  end
end
