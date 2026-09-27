# frozen_string_literal: true

require "quaack/enclave/deparse"
require "quaack/enclave/error_filter"
require "quaack/enclave/supported_sql"

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

  # pg_query's deparse bugs that 20260923-30 and 20260923-55 found, and
  # that parenthesizing (20260924-4) doesn't fix, since the SQL they're in
  # isn't supported. Each deparses to SQL that doesn't parse.
  repros = {
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

    # The added parentheses can push the tree past pg_query's depth limit.
    it "refuses a query too deep to deparse, rather than raise something else" do
      predicate = (1..150).reduce("e") { |inner, _| "(#{inner} OR b) IS TRUE" }
      expect { described_class.faithfully(tree("SELECT 1 FROM t WHERE #{predicate}")) }.to refused
    end

    repros.each do |name, sql|
      it "refuses #{name}" do
        expect { described_class.faithfully(tree(sql)) }.to refused
      end
    end

    # pg_query's deparser leaves out parentheses that some operands need,
    # so without them the SQL parses back as a different query, or not at
    # all. Each of these round-trips, spelled as shown.
    describe "an operand that needs parentheses" do
      # Whether pg_query's deparser, on its own, writes SQL that parses as
      # a different query or doesn't parse.
      def mangled_by_deparser?(sql)
        deparsed = PgQuery.deparse(tree(sql))
        described_class.comparable(PgQuery.parse(deparsed).tree) != described_class.comparable(tree(sql))
      rescue PgQuery::ParseError
        true
      end

      {
        # The ones the reviews of 20260923-55 found (20260924-4).
        "SELECT * FROM t WHERE (a OR b) IS NULL" => nil,
        "SELECT * FROM t WHERE (a AND b) IS NOT NULL" => nil,
        "SELECT * FROM t WHERE (NOT a) IS NULL" => nil,
        "SELECT * FROM t WHERE (a AND b) IN (true)" => nil,
        "SELECT * FROM t WHERE (a AND b) = ANY(c)" => nil,
        "SELECT * FROM t WHERE (a = 1) = ANY(ARRAY[true])" => nil,
        "SELECT * FROM t WHERE a IS NOT DISTINCT FROM (b AND c)" => nil,
        "SELECT * FROM t WHERE a BETWEEN (b AND c) AND d" => nil,
        "SELECT created_at AT TIME ZONE ('UTC' || '') FROM t" => nil,
        # The two that 20260923-30 and 20260923-55 found. The left operand
        # of the first needs no parentheses, since = binds tighter than IS.
        "SELECT * FROM public.t WHERE (status = $1) IS NOT DISTINCT FROM (true AND false)" =>
          "SELECT * FROM public.t WHERE status = $1 IS NOT DISTINCT FROM (true AND false)",
        "SELECT (ARRAY(SELECT 1))[1]" => nil,
        # More of the same family.
        "SELECT * FROM t WHERE (a IS DISTINCT FROM b) IS NULL" => nil,
        "SELECT * FROM t WHERE (a IS NOT DISTINCT FROM b) IS NOT FALSE" => nil,
        "SELECT * FROM t WHERE (a = 1) IN (true, false)" => nil,
        # NOT x IN (SELECT ...) is NOT (x IN (SELECT ...)), as NOT IN is.
        "SELECT * FROM t WHERE (a + 1 = b) NOT IN (SELECT c FROM u)" =>
          "SELECT * FROM t WHERE NOT ((a + 1) = b) IN (SELECT c FROM u)",
        "SELECT * FROM t WHERE (a < b) = ALL(c)" => nil,
        "SELECT * FROM t WHERE (a = 1) = ANY(SELECT c FROM u)" =>
          "SELECT * FROM t WHERE (a = 1) = ANY (SELECT c FROM u)",
        "SELECT * FROM t WHERE (a LIKE b) ILIKE c" => nil,
        "SELECT * FROM t WHERE a LIKE (b LIKE c)" => nil,
        "SELECT * FROM t WHERE a BETWEEN b AND (c OR d)" => nil,
        "SELECT * FROM t WHERE a NOT BETWEEN SYMMETRIC (b IS NULL) AND c" => nil,
        "SELECT * FROM t WHERE a BETWEEN (NOT b) AND c" => nil,
        "SELECT * FROM t WHERE x = (a = ANY(SELECT 1))" => "SELECT * FROM t WHERE x = (a = ANY (SELECT 1))",
        "SELECT * FROM t WHERE x + (a IN (SELECT 1)) > 0" => "SELECT * FROM t WHERE (x + (a IN (SELECT 1))) > 0",
        "SELECT -(a AT TIME ZONE 'UTC'), -(a COLLATE \"C\") FROM t" =>
          "SELECT - (a AT TIME ZONE 'UTC'), - (a COLLATE \"C\") FROM t",
        "SELECT (a OR b) COLLATE \"C\", (a AT TIME ZONE 'UTC') COLLATE \"C\" FROM t" => nil,
        "SELECT (a + b) AT TIME ZONE 'UTC', a AT TIME ZONE (b AT TIME ZONE 'UTC'), (NOT a) AT LOCAL FROM t" => nil,
        "SELECT position((NOT a) IN b), position(a IN (b = ANY(SELECT 1))) FROM t" =>
          "SELECT POSITION((NOT a) IN b), POSITION(a IN (b = ANY (SELECT 1))) FROM t",
        # An operand's loosest end can be inside it: the IN inside AT TIME
        # ZONE, or inside the cast, and the NOT on the right of AT TIME
        # ZONE and the prefix operator on the right of the inner one.
        "SELECT y || ((a IN (SELECT 1)) AT TIME ZONE 'UTC') FROM t" =>
          "SELECT y || (a IN (SELECT 1) AT TIME ZONE 'UTC') FROM t",
        "SELECT y || ((a IN (SELECT 1))::int) FROM t" => "SELECT y || (a IN (SELECT 1)::int) FROM t",
        "SELECT * FROM t WHERE (a AT TIME ZONE (NOT b)) IS NULL" =>
          "SELECT * FROM t WHERE (a AT TIME ZONE NOT b) IS NULL",
        "SELECT (a AT TIME ZONE (@ b)) AT TIME ZONE 'UTC' FROM t" =>
          "SELECT (a AT TIME ZONE @ b) AT TIME ZONE 'UTC' FROM t",
        # Each comparison binds at =, each LIKE form is LIKE inside ANY, and
        # every BETWEEN form parenthesizes its bounds (20260924-4 review).
        "SELECT * FROM t WHERE (a > b) = ANY(c)" => nil,
        "SELECT * FROM t WHERE (a <= b) = ANY(c)" => nil,
        "SELECT * FROM t WHERE (a > b) IN (true)" => nil,
        "SELECT * FROM t WHERE a LIKE (b NOT LIKE ANY(c))" => nil,
        "SELECT * FROM t WHERE a LIKE (b ILIKE ANY(c))" => nil,
        "SELECT * FROM t WHERE a LIKE (b NOT ILIKE ANY(c))" => nil,
        "SELECT * FROM t WHERE a BETWEEN SYMMETRIC b || c AND (d OR e)" => nil,
        # A cast of a COLLATE isn't a b_expr, though a cast of a column is.
        "SELECT * FROM t WHERE a BETWEEN (b COLLATE \"C\")::text AND c" =>
          "SELECT * FROM t WHERE a BETWEEN (b COLLATE \"C\"::text) AND c",
        # WITH TIES takes only a c_expr, and the deparser writes a NULL
        # count as ALL, which WITH TIES can't have.
        "SELECT a FROM t ORDER BY a FETCH FIRST (b IN (SELECT 1)) ROWS WITH TIES" => nil,
        "SELECT a FROM t ORDER BY a FETCH FIRST (b = ANY(SELECT 1)) ROWS WITH TIES" =>
          "SELECT a FROM t ORDER BY a FETCH FIRST (b = ANY (SELECT 1)) ROWS WITH TIES",
        "SELECT a FROM t ORDER BY a FETCH FIRST (b < ALL (SELECT 1)) ROWS WITH TIES" => nil,
        "SELECT a FROM t ORDER BY a FETCH FIRST (NULL) ROWS WITH TIES" => nil,
        # A prefix operator binds looser than + - * / % and ^, so it leaves
        # AT TIME ZONE open on its right to them.
        "SELECT (a AT TIME ZONE @ b) + c, (a AT TIME ZONE @ b) - c FROM t" => nil,
        "SELECT (a AT TIME ZONE @ b) * c, (a AT TIME ZONE @ b) / c, (a AT TIME ZONE @ b) % c FROM t" => nil,
        "SELECT (a AT TIME ZONE @ b) ^ c FROM t" => nil,
        # ANY leaves its left operand bare, so it shows each level: + under
        # * / and %, * under ^, and || under +. Each associates left.
        "SELECT (a + b) * ANY(c), (a - b) / ANY(c), (a + b) % ANY(c), (a * b) ^ ANY(c) FROM t" => nil,
        "SELECT (a + b) + ANY(c), (a * b) * ANY(c), (a ^ b) ^ ANY(c), (a || b) + ANY(c) FROM t" =>
          "SELECT a + b + ANY(c), a * b * ANY(c), a ^ b ^ ANY(c), (a || b) + ANY(c) FROM t",
        # OPERATOR(pg_catalog.=) binds as any other OPERATOR does, not as =.
        "SELECT y OPERATOR(pg_catalog.=) (a IN (SELECT 1)) FROM t" => nil,
        "SELECT ((a OR b))[1], ((-1))[1], ('{1}')[1], ((a IS NULL))[1:2], (EXISTS (SELECT 1))[1] FROM t" =>
          "SELECT (a OR b)[1], (-1)[1], ('{1}')[1], (a IS NULL)[1:2], (EXISTS (SELECT 1))[1] FROM t"
      }.each do |sql, spelled|
        it "round-trips #{sql}" do
          expect(mangled_by_deparser?(sql)).to be(true)
          expect(described_class.faithfully(tree(sql))).to eq(spelled || sql)
        end
      end

      # Only where they're needed, so an operand that binds tighter than
      # what's around it is written as the deparser writes it.
      [
        "SELECT * FROM t WHERE a + 1 BETWEEN b * 2 AND c - 3",
        "SELECT * FROM t WHERE x LIKE 'a' || b AND (a || b) LIKE (c || '%')",
        "SELECT * FROM t WHERE (a IN (1)) BETWEEN b AND c AND (a OR b) IS TRUE",
        "SELECT * FROM t WHERE a + 1 IS NULL AND b = 2 IS NOT TRUE",
        "SELECT * FROM t WHERE NOT a = 1 OR b IN (1) IS TRUE",
        "SELECT * FROM t WHERE a IS NOT DISTINCT FROM b + 1",
        # BETWEEN's lower bound can hold IS DISTINCT FROM and a cast bare.
        "SELECT * FROM t WHERE a BETWEEN b IS DISTINCT FROM c AND d AND a BETWEEN b::int AND c",
        "SELECT * FROM t WHERE a = ANY(b) AND c NOT IN (SELECT 1) AND lower(d) ILIKE $1",
        "SELECT created_at AT TIME ZONE 'UTC', -a::int, (-1)::int, a COLLATE \"C\" || b FROM t",
        "SELECT a[1], $1[2], (SELECT b)[1], (a + b)[1], (a::int[])[1] FROM t",
        # AT TIME ZONE associates left, the deparser parenthesizes an array
        # or a subscript it subscripts, a sign is a b_expr, and these are
        # plain calls, not AT TIME ZONE or POSITION.
        "SELECT a AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago' FROM t",
        "SELECT (ARRAY[1, 2])[1], (a[1])[2] FROM t",
        # || binds as the prefix operator does, so it takes the AT TIME
        # ZONE, and a NULL count without WITH TIES can be written as ALL.
        "SELECT (a AT TIME ZONE @ b) || c FROM t",
        "SELECT a FROM t ORDER BY a FETCH FIRST (b + 1) ROWS WITH TIES",
        "SELECT a FROM t LIMIT NULL",
        "SELECT * FROM t WHERE a BETWEEN -b AND c AND position(-a IN b) > 0",
        "SELECT pg_catalog.timezone('UTC', a || b), pg_catalog.timezone(a IS NULL), " \
        "pg_catalog.position(a IS NULL, b) FROM t"
      ].each do |sql|
        it "adds none to #{sql}" do
          expect(described_class.faithfully(tree(sql))).to eq(PgQuery.deparse(tree(sql)))
        end
      end

      it "doesn't change the tree it's given" do
        given = tree("SELECT * FROM t WHERE (a OR b) IS NULL")
        before = given.to_proto
        expect(described_class.faithfully(given)).to eq("SELECT * FROM t WHERE (a OR b) IS NULL")
        expect(given.to_proto).to eq(before)
      end
    end

    # Every supported operand in every place an operand goes, then one in
    # each place in each part of a query, and then each place inside each
    # other place. Anything that doesn't parse, or that SupportedSql
    # refuses, is left out.
    describe "every operand in every place" do
      operands = [
        "a OR b", "a AND b", "NOT a", "a IS NULL", "a IS NOT NULL", "a IS TRUE", "a IS NOT UNKNOWN", "a = 1", "a < 1",
        "a <> 1", "a >= 1", "a + 1", "a - 1", "a * 1", "a / 1", "a % 1", "a ^ 1", "a || b", "a -> b", "-a", "+a", "@ a",
        "a IS DISTINCT FROM b", "a IS NOT DISTINCT FROM b", "a IN (1)", "a NOT IN (1)", "a LIKE b", "a NOT ILIKE b",
        "a LIKE b ESCAPE c", "a BETWEEN b AND c", "a NOT BETWEEN SYMMETRIC b AND c", "a = ANY(b)", "a < ALL(b)",
        "a LIKE ANY(b)", "a COLLATE \"C\"", "a AT TIME ZONE b", "a AT LOCAL", "a::int", "-1", "-1.5", "1.5",
        "a OPERATOR(pg_catalog.+) b", "OPERATOR(pg_catalog.-) a", "a[1]", "NULLIF(a, b)", "a IN (SELECT 1)",
        "a = ANY(SELECT 1)", "a NOT IN (SELECT 1)", "EXISTS (SELECT 1)", "ARRAY(SELECT 1)", "(SELECT 1)",
        "CASE WHEN a THEN 1 END", "extract(year FROM a)", "f(a)", "ARRAY[a]", "'x'", "$1", "true", "NULL"
      ]
      places = [
        "X IS NULL", "X IS NOT NULL", "X IS TRUE", "X IS NOT FALSE", "X IS UNKNOWN", "X = y", "y = X", "X < y",
        "y <> X", "X + y", "y + X", "y - X", "X * y", "y / X", "X ^ y", "y ^ X", "- X", "+ X", "@ X", "X || y",
        "y || X", "X -> y", "X OPERATOR(pg_catalog.+) y", "y OPERATOR(pg_catalog.+) X", "OPERATOR(pg_catalog.-) X",
        "X = ANY(y)", "y = ANY(X)", "X < ALL(y)", "X LIKE ANY(y)", "y = ANY(ARRAY[X])", "X IS DISTINCT FROM y",
        "y IS DISTINCT FROM X", "X IS NOT DISTINCT FROM y", "y IS NOT DISTINCT FROM X", "X IN (y)", "y IN (X)",
        "X NOT IN (y, z)", "X LIKE y", "y LIKE X", "X ILIKE y", "y NOT ILIKE X", "y LIKE z ESCAPE X",
        "X BETWEEN y AND z", "y BETWEEN X AND z", "y BETWEEN z AND X", "y NOT BETWEEN SYMMETRIC X AND z",
        "X NOT BETWEEN y AND z", "X AND y", "y OR X", "NOT X", "X::int", "(X)[1]", "(X)[1:2]", "X COLLATE \"C\"",
        "X AT TIME ZONE y", "y AT TIME ZONE X", "X AT LOCAL", "X IN (SELECT 1)", "X = ANY(SELECT 1)",
        "X < ALL (SELECT 1)", "X NOT IN (SELECT 1)", "CASE X WHEN y THEN 1 END", "CASE y WHEN X THEN 1 END",
        "NULLIF(X, y)", "extract(year FROM X)", "substring(X FROM y FOR z)", "substring(y FROM X)",
        "position(X IN y)", "position(y IN X)", "overlay(X PLACING y FROM 1 FOR 2)", "trim(both X from y)",
        "trim(leading y from X)", "ARRAY[X]", "coalesce(X, y)", "greatest(X, y)", "f(X)", "f(k => X)",
        "CAST(X AS int)", "count(*) FILTER (WHERE X)", "sum(a) OVER (ORDER BY X ROWS X PRECEDING)"
      ]
      wholes = [
        "SELECT X FROM t", "SELECT * FROM t JOIN u ON X", "SELECT * FROM t WHERE X", "SELECT * FROM t LIMIT X OFFSET X",
        "SELECT * FROM t ORDER BY X USING <", "SELECT DISTINCT ON (X) a FROM t GROUP BY X HAVING X", "VALUES (X)"
      ]

      fill = ->(template, operand) { template.gsub("X", "(#{operand})") }

      def supported(sql)
        parse = PgQuery.parse(sql)
        Quaack::Enclave::SupportedSql.check!(parse)
        parse.tree
      rescue PgQuery::ParseError, Quaack::Enclave::SupportedSql::Error
        nil
      end

      def refused_of(sqls)
        trees = sqls.filter_map { |sql| (tree = supported(sql)) && [sql, tree] }
        expect(trees.size).to be > sqls.size / 2
        trees.reject do |_sql, tree|
          described_class.faithfully(tree)
        rescue described_class::Error
          false
        end.map(&:first)
      end

      it "round-trips each operand in each place" do
        sqls = places.flat_map do |place|
          operands.map do |operand|
            fill.call("SELECT X FROM t", fill.call(place, operand))
          end
        end
        expect(refused_of(sqls)).to eq([])
      end

      it "round-trips an operand in each place in each part of a query" do
        sqls = wholes.flat_map { |whole| places.map { |place| fill.call(whole, fill.call(place, "a OR b")) } }
        expect(refused_of(sqls)).to eq([])
      end

      it "round-trips each place inside each other place" do
        sqls = places.flat_map do |outer|
          places.map do |inner|
            fill.call("SELECT X FROM t", fill.call(outer, fill.call(inner, "a")))
          end
        end
        expect(refused_of(sqls)).to eq([])
      end
    end

    # A fingerprint ignores constants, so it can't be what's compared.
    it "compares constants, not just structure" do
      changed = tree("SELECT 10")
      changed.stmts[0].stmt.select_stmt.target_list[0].res_target.val =
        PgQuery::Node.new(a_const: PgQuery::A_Const.new(fval: PgQuery::Float.new(fval: "10")))
      expect(PgQuery.deparse(changed)).to eq("SELECT 10")
      expect { described_class.faithfully(changed) }.to refused
    end

    # Each tree below is edited so the deparser loses one scalar field, and
    # the tree it parses back differs from it in that one field alone. So
    # each fails if that field, or every field of its type, isn't compared.
    describe "one scalar that doesn't survive" do
      def select_of(sql) = tree(sql).tap { |t| yield t.stmts[0].stmt.select_stmt }

      # An int32. interval's first typmod is a field mask. The deparser
      # writes only the masks it knows, so this one comes back as the
      # full range, 32767.
      it "refuses a changed Integer ival" do
        changed = select_of("SELECT '1'::interval(3)") do |select|
          select.target_list[0].res_target.val.type_cast.type_name.typmods[0].a_const.ival.ival = 12_345
        end
        expect(PgQuery.deparse(changed)).to eq("SELECT '1'::interval(3)")
        expect { described_class.faithfully(changed) }.to refused
      end

      # Enums. The deparser writes nothing for a value it doesn't know, so
      # each comes back as the default.
      it "refuses a changed SortBy direction" do
        changed = select_of("SELECT a FROM public.t ORDER BY a") { |s| s.sort_clause[0].sort_by.sortby_dir = 7 }
        expect { described_class.faithfully(changed) }.to refused
      end

      it "refuses a changed SortBy nulls ordering" do
        changed = select_of("SELECT a FROM public.t ORDER BY a") { |s| s.sort_clause[0].sort_by.sortby_nulls = 9 }
        expect { described_class.faithfully(changed) }.to refused
      end

      it "refuses a changed A_Expr kind" do
        changed = select_of("SELECT a FROM public.t WHERE a = 1") { |s| s.where_clause.a_expr.kind = 99 }
        expect(PgQuery.deparse(changed)).to eq("SELECT a FROM public.t WHERE a = 1")
        expect { described_class.faithfully(changed) }.to refused
      end

      it "refuses a changed BoolExpr boolop" do
        changed = select_of("SELECT a FROM public.t WHERE a AND b") { |s| s.where_clause.bool_expr.boolop = 9 }
        expect(PgQuery.deparse(changed)).to eq("SELECT a FROM public.t WHERE a AND b")
        expect { described_class.faithfully(changed) }.to refused
      end

      # An A_Const that's NULL and also holds a boolean. The deparser
      # writes NULL, so the boolean is lost.
      it "refuses a lost A_Const boolval" do
        changed = select_of("SELECT NULL") do |select|
          select.target_list[0].res_target.val.a_const.boolval = PgQuery::Boolean.new(boolval: true)
        end
        expect(PgQuery.deparse(changed)).to eq("SELECT NULL")
        expect { described_class.faithfully(changed) }.to refused
      end

      # A bool. The deparser reads WITH RECURSIVE from the WithClause, and
      # the parser never sets cterecursive.
      it "refuses a changed CommonTableExpr cterecursive" do
        changed = select_of("WITH c AS (SELECT 1) SELECT * FROM c") do |select|
          select.with_clause.ctes[0].common_table_expr.cterecursive = true
        end
        expect(PgQuery.deparse(changed)).to eq("WITH c AS (SELECT 1) SELECT * FROM c")
        expect { described_class.faithfully(changed) }.to refused
      end
    end

    # The parser cuts identifiers to 63 bytes, so a longer name in a built
    # tree comes back as a different name.
    it "refuses a name the parser would cut short" do
      changed = tree("SELECT a FROM public.t")
      changed.stmts[0].stmt.select_stmt.from_clause[0].range_var.relname = "t" * 64
      expect { described_class.faithfully(changed) }.to refused
    end

    # CREATE TABLESPACE's location is its directory, a string, not a place
    # in the text.
    it "clears only the int32 fields named for a location" do
      compared = described_class.comparable(tree("CREATE TABLESPACE space LOCATION '/data/space'"))
      expect(compared.stmts[0].stmt.create_table_space_stmt.location).to eq("/data/space")
      expect(described_class.comparable(tree("SELECT a")).stmts[0].stmt.select_stmt.target_list[0].res_target.location)
        .to eq(0)
    end

    # Deeper than protobuf's default limit of 100, so the copy that's
    # compared has to allow more.
    it "deparses a tree hundreds of levels deep" do
      sql = "SELECT #{(["1"] * 450).join(" + ")}"
      expect(described_class.faithfully(tree(sql))).to eq(PgQuery.deparse(tree(sql)))
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
      expect { described_class.expression(where_of("xmlexists('//a' PASSING BY REF (x::xml))")) }.to refused
    end

    it "parenthesizes an operand that needs it" do
      expect(described_class.expression(where_of("(a = 1) IS NOT DISTINCT FROM (b AND c)")))
        .to eq("a = 1 IS NOT DISTINCT FROM (b AND c)")
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

    # Each also has an operand, holding the sentinel, that gets
    # parentheses, so the error comes after they're added. The mismatch is
    # a table name the parser would cut short.
    {
      "a mismatch" => ["SELECT '#{sentinel}' AS \"#{sentinel}\" FROM public.t " \
                       "WHERE (status = '#{sentinel}') IS NOT DISTINCT FROM (true AND false)",
                       ->(t) { t.stmts[0].stmt.select_stmt.from_clause[0].range_var.relname = "t" * 64 }],
      "SQL that doesn't parse back" => ["SELECT '#{sentinel}' AS \"#{sentinel}\", ('#{sentinel}' OR b) IS NULL, " \
                                        "xmlexists('//a' PASSING BY REF (x::xml))", nil]
    }.each do |what, (sql, change)|
      it "never shows up in the error for #{what}" do
        expect(sql.scan(sentinel).size).to eq(3)
        given = tree(sql).tap { |t| change&.call(t) }
        error = nil
        expect { described_class.faithfully(given) }.to(refused { |e| error = e })
        line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "1")
        expect(line).to eq('{"type":"error","step":"1","rule":"deparse_mismatch"}')
        expect([error.message, error.full_message, line]).to all(satisfy { |text| !text.include?(sentinel) })
      end
    end
  end
end
