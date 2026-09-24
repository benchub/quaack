# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/supported_sql"

# Table-driven: each case is one SQL string and what check! should do with
# it. No database, since the check reads only the parse.
RSpec.describe Quaack::Enclave::SupportedSql do
  def check(sql) = described_class.check!(PgQuery.parse(sql))

  def refusal(detail)
    raise_error(described_class::Error, "unsupported_construct: #{detail}") do |error|
      expect(error.rule).to eq("unsupported_construct")
      expect(error.cause).to be_nil
    end
  end

  # Each case uses at least one entry of the list, and together they use
  # every entry (see "covers every entry of the list" below).
  supported = {
    "a plain SELECT" => "SELECT 1",
    "a table and its columns" => "SELECT o.id, status FROM public.orders o",
    "ONLY and a star" => "SELECT * FROM ONLY public.orders, public.items *",
    "TABLE" => "TABLE public.orders",
    "inner, outer, and cross joins" =>
      "SELECT * FROM a JOIN b ON a.id = b.id LEFT JOIN c ON true FULL JOIN d ON false CROSS JOIN e",
    "USING and NATURAL" => "SELECT * FROM a JOIN b USING (id) AS j NATURAL RIGHT JOIN c",
    "a subquery in FROM" => "SELECT * FROM (SELECT 1 AS x) s(y)",
    "LATERAL" => "SELECT * FROM a, LATERAL (SELECT a.x) s",
    "a function in FROM" => "SELECT * FROM generate_series(1, 3) g, unnest(ARRAY[1, 2]) u",
    "WITH ORDINALITY and LATERAL functions" => "SELECT * FROM LATERAL generate_series(1, 3) WITH ORDINALITY AS g(n, i)",
    "ROWS FROM one function" => "SELECT * FROM ROWS FROM (generate_series(1, 3)) g",
    "VALUES" => "SELECT * FROM (VALUES (1, 'x'), (2, 'y')) v(a, b)",
    "set operations" => "SELECT 1 UNION SELECT 2 INTERSECT SELECT 3 EXCEPT ALL SELECT 4",
    "a CTE" => "WITH c AS (SELECT 1) SELECT * FROM c",
    "a recursive CTE" =>
      "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 5) SELECT n FROM c",
    "MATERIALIZED and NOT MATERIALIZED" =>
      "WITH c AS MATERIALIZED (SELECT 1), d AS NOT MATERIALIZED (SELECT 2) SELECT * FROM c, d",
    "subqueries of every kind" =>
      "SELECT EXISTS (SELECT 1), (SELECT 1), ARRAY(SELECT 1), 1 IN (SELECT 1), 1 = ANY (SELECT 1), " \
      "1 > ALL (SELECT 1)",
    "CASE, searched and simple" => "SELECT CASE WHEN x THEN 1 ELSE 2 END, CASE x WHEN 1 THEN 2 END FROM t",
    "aggregates" =>
      "SELECT count(*), count(DISTINCT x), array_agg(x ORDER BY y DESC NULLS LAST), " \
      "sum(x) FILTER (WHERE y > 0), percentile_cont(0.5) WITHIN GROUP (ORDER BY x) " \
      "FROM t GROUP BY z HAVING count(*) > 1",
    "GROUP BY DISTINCT" => "SELECT a, b FROM t GROUP BY DISTINCT a, b",
    "window functions" =>
      "SELECT rank() OVER (PARTITION BY x ORDER BY y ROWS BETWEEN 1 PRECEDING AND CURRENT ROW), " \
      "sum(x) OVER w FROM t WINDOW w AS (ORDER BY y RANGE UNBOUNDED PRECEDING EXCLUDE TIES)",
    "operators" => "SELECT -x, x + 1, x OPERATOR(pg_catalog.+) 1, x || 'a', x @> y, x ~ 'b' FROM t",
    "AND, OR, and NOT" => "SELECT x FROM t WHERE (x AND y) OR NOT z",
    "casts" =>
      "SELECT x::int, CAST(x AS numeric(10, 2)), int '1', x::text[], interval '1' minute, " \
      "x::pg_catalog.varchar(3) FROM t",
    "a parameter" => "SELECT $1::int",
    "IN and NOT IN" => "SELECT x FROM t WHERE x IN (1, 2) AND x NOT IN (3)",
    "ANY" => "SELECT x FROM t WHERE x = ANY ('{1}')",
    "ALL" => "SELECT x FROM t WHERE x <> ALL (ARRAY[1])",
    "LIKE" => "SELECT x FROM t WHERE x LIKE 'a' AND x NOT LIKE 'b' ESCAPE '!'",
    "ILIKE" => "SELECT x FROM t WHERE x ILIKE 'a' AND x NOT ILIKE 'b'",
    "BETWEEN" => "SELECT x FROM t WHERE x BETWEEN 1 AND 2",
    "NOT BETWEEN" => "SELECT x FROM t WHERE x NOT BETWEEN 1 AND 2",
    "BETWEEN SYMMETRIC" => "SELECT x FROM t WHERE x BETWEEN SYMMETRIC 1 AND 2",
    "NOT BETWEEN SYMMETRIC" => "SELECT x FROM t WHERE x NOT BETWEEN SYMMETRIC 1 AND 2",
    "IS DISTINCT FROM" => "SELECT x FROM t WHERE x IS DISTINCT FROM y",
    "IS NOT DISTINCT FROM" => "SELECT x FROM t WHERE x IS NOT DISTINCT FROM y",
    "NULLIF" => "SELECT nullif(x, 1) FROM t",
    "IS NULL" => "SELECT x FROM t WHERE x IS NULL OR x IS NOT NULL OR x ISNULL",
    "IS TRUE and its kin" => "SELECT x IS TRUE, x IS NOT FALSE, x IS UNKNOWN FROM t",
    "COALESCE" => "SELECT coalesce(x, 1) FROM t",
    "GREATEST and LEAST" => "SELECT greatest(x, 1), least(x, 2) FROM t",
    "arrays" => "SELECT ARRAY[1, 2], ARRAY[[1], [2]] FROM t",
    "array subscripts" => "SELECT x[1], x[1:2], (ARRAY[1, 2])[1] FROM t",
    "COLLATE" => "SELECT x COLLATE \"C\" FROM t ORDER BY x COLLATE pg_catalog.\"default\"",
    "SQL-value functions" =>
      "SELECT CURRENT_DATE, CURRENT_TIMESTAMP(0), LOCALTIME, LOCALTIMESTAMP, CURRENT_USER, SESSION_USER",
    "extract" => "SELECT extract(year FROM x) FROM t",
    "overlay" => "SELECT overlay(x PLACING 'a' FROM 1 FOR 2) FROM t",
    "position" => "SELECT position('a' IN x) FROM t",
    "substring" => "SELECT substring(x FROM 1 FOR 2), substring(x FROM 'a') FROM t",
    "trim" => "SELECT trim(x) FROM t",
    "trim leading" => "SELECT trim(LEADING 'a' FROM x) FROM t",
    "trim trailing" => "SELECT trim(TRAILING FROM x) FROM t",
    "AT TIME ZONE" => "SELECT x AT TIME ZONE 'UTC', x AT LOCAL FROM t",
    "constants of every kind" => "SELECT 1, 1.5, 1e10, 'x', true, NULL, B'101', X'1F'",
    "a named argument" => "SELECT f(a => 1, b := 2), f(VARIADIC ARRAY[1]) FROM t",
    "DISTINCT and DISTINCT ON" => "SELECT DISTINCT x FROM t UNION SELECT DISTINCT ON (y) y FROM t",
    "ORDER BY, LIMIT, and OFFSET" => "SELECT x FROM t ORDER BY x DESC, y USING < LIMIT 10 OFFSET 5",
    "LIMIT ALL" => "SELECT x FROM t LIMIT ALL",
    "FETCH FIRST" => "SELECT x FROM t ORDER BY x OFFSET 1 ROWS FETCH FIRST 3 ROWS ONLY",
    "FETCH FIRST WITH TIES" => "SELECT x FROM t ORDER BY x FETCH FIRST ROWS WITH TIES"
  }.freeze

  describe "a supported query" do
    supported.each do |construct, sql|
      it "passes #{construct}" do
        expect(check(sql)).to be_nil
      end
    end

    # Every node type, A_Expr kind, SQL-syntax function, and subquery kind
    # the list allows shows up in some case above, so dropping any one entry
    # turns a case red.
    it "covers every entry of the list" do
      used = Hash.new { |hash, key| hash[key] = Set.new }
      supported.each_value { |sql| uses(PgQuery.parse(sql).tree, used) }

      expect(used[:nodes]).to eq(described_class::NODES.keys.to_set)
      expect(used[:kinds]).to eq(described_class::A_EXPR_KINDS.to_set)
      expect(used[:sublinks]).to eq(described_class::SUBLINK_TYPES.to_set)
      expect(used[:syntax]).to eq(described_class::SQL_SYNTAX_FUNCTIONS.to_set)
    end

    def uses(node, used)
      case node
      when Google::Protobuf::RepeatedField then node.each { |child| uses(child, used) }
      when PgQuery::Node then uses(node.inner, used)
      when Google::Protobuf::MessageExts
        record(node, used)
        node.class.descriptor.each { |field| uses(field.get(node), used) }
      end
    end

    def record(node, used)
      used[:nodes] << node.class
      case node
      when PgQuery::A_Expr then used[:kinds] << node.kind
      when PgQuery::SubLink then used[:sublinks] << node.sub_link_type
      when PgQuery::FuncCall then used[:syntax] << syntax_name(node) if node.funcformat == :COERCE_SQL_SYNTAX
      end
    end

    def syntax_name(func) = func.funcname.map { |name| name.string.sval }.join(".")
  end

  # [SQL, the detail the message should give].
  refused = {
    "INSERT" => ["INSERT INTO t VALUES (1)", "InsertStmt"],
    "UPDATE" => ["UPDATE t SET x = 1", "UpdateStmt"],
    "DELETE" => ["DELETE FROM t", "DeleteStmt"],
    "MERGE" => ["MERGE INTO t USING u ON true WHEN MATCHED THEN DO NOTHING", "MergeStmt"],
    "a data-modifying CTE" => ["WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", "DeleteStmt"],
    "an INSERT in a CTE" => ["WITH i AS (INSERT INTO t VALUES (1) RETURNING *) SELECT * FROM i", "InsertStmt"],
    "an UPDATE in a CTE" => ["WITH u AS (UPDATE t SET x = 1 RETURNING *) SELECT * FROM u", "UpdateStmt"],
    "SELECT INTO" => ["SELECT * INTO new_t FROM t", "IntoClause"],
    "FOR UPDATE" => ["SELECT * FROM t FOR UPDATE", "LockingClause"],
    "FOR SHARE OF" => ["SELECT * FROM t FOR SHARE OF t NOWAIT", "LockingClause"],
    "FOR UPDATE in a subquery" => ["SELECT * FROM (SELECT * FROM t FOR UPDATE) s", "LockingClause"],
    "EXPLAIN" => ["EXPLAIN SELECT 1", "ExplainStmt"],
    "SET" => ["SET search_path = x", "VariableSetStmt"],
    "CREATE INDEX" => ["CREATE INDEX ON t (x)", "IndexStmt"],
    "two statements" => ["SELECT 1; SELECT 2", "ParseResult with 2 statements, not one"],
    "no statement" => ["", "ParseResult with 0 statements, not one"],
    "TABLESAMPLE" => ["SELECT * FROM t TABLESAMPLE system (1)", "RangeTableSample"],
    "ROWS FROM several functions" =>
      ["SELECT * FROM ROWS FROM (generate_series(1, 2), generate_series(1, 3)) r",
       "RangeFunction with ROWS FROM over several functions"],
    "a column definition list" => ["SELECT * FROM f() AS x(a int)", "ColumnDef"],
    "something other than a function call in FROM" =>
      ["SELECT * FROM coalesce(1, 2) c", "RangeFunction over CoalesceExpr"],
    "JSON_TABLE" => ["SELECT * FROM JSON_TABLE('[]', '$' COLUMNS (a int PATH '$.a')) jt", "JsonTable"],
    "XMLTABLE" => ["SELECT * FROM XMLTABLE('/r' PASSING '<r/>' COLUMNS a int) xt", "RangeTableFunc"],
    "CYCLE" =>
      ["WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) CYCLE n SET m USING p SELECT * FROM c",
       "CTECycleClause"],
    "SEARCH" =>
      ["WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) SEARCH DEPTH FIRST BY n SET s " \
       "SELECT * FROM c", "CTESearchClause"],
    "ROW" => ["SELECT ROW(1, 2)", "RowExpr"],
    "ROW after a supported item" => ["SELECT 1, 2, ROW(1, 2)", "RowExpr"],
    "a row comparison" => ["SELECT x FROM t WHERE (x, y) < (1, 2)", "RowExpr"],
    "a row IN a subquery" => ["SELECT x FROM t WHERE (x, y) IN (SELECT 1, 2)", "RowExpr"],
    "GROUPING SETS" => ["SELECT x FROM t GROUP BY GROUPING SETS ((x), ())", "GroupingSet"],
    "ROLLUP" => ["SELECT x FROM t GROUP BY ROLLUP (x)", "GroupingSet"],
    "CUBE" => ["SELECT x FROM t GROUP BY CUBE (x)", "GroupingSet"],
    "an empty grouping set" => ["SELECT count(*) FROM t GROUP BY ()", "GroupingSet"],
    "GROUPING" => ["SELECT GROUPING(x) FROM t GROUP BY x", "GroupingFunc"],
    "an XML function" => ["SELECT xmlelement(name x)", "XmlExpr"],
    "IS DOCUMENT" => ["SELECT x IS DOCUMENT FROM t", "XmlExpr"],
    "XMLSERIALIZE" => ["SELECT xmlserialize(document x AS text) FROM t", "XmlSerialize"],
    "JSON_OBJECT" => ["SELECT json_object('a': 1)", "JsonObjectConstructor"],
    "JSON_ARRAY" => ["SELECT json_array(1)", "JsonArrayConstructor"],
    "JSON_VALUE" => ["SELECT json_value(x, '$') FROM t", "JsonFuncExpr"],
    "IS JSON" => ["SELECT x IS JSON FROM t", "JsonIsPredicate"],
    "JSON" => ["SELECT json(x) FROM t", "JsonParseExpr"],
    "JSON_SCALAR" => ["SELECT json_scalar(1)", "JsonScalarExpr"],
    "JSON_SERIALIZE" => ["SELECT json_serialize(x) FROM t", "JsonSerializeExpr"],
    "JSON_ARRAYAGG" => ["SELECT json_arrayagg(x) FROM t", "JsonArrayAgg"],
    "JSON_OBJECTAGG" => ["SELECT json_objectagg(x: y) FROM t", "JsonObjectAgg"],
    "normalize with a normal form" =>
      ["SELECT normalize(x, NFC) FROM t", "FuncCall pg_catalog.normalize written in SQL syntax"],
    "normalize" => ["SELECT normalize(x) FROM t", "FuncCall pg_catalog.normalize written in SQL syntax"],
    "IS NORMALIZED" =>
      ["SELECT x IS NFKD NORMALIZED FROM t", "FuncCall pg_catalog.is_normalized written in SQL syntax"],
    "SYSTEM_USER" => ["SELECT SYSTEM_USER", "FuncCall pg_catalog.system_user written in SQL syntax"],
    "COLLATION FOR" =>
      ["SELECT collation for (x) FROM t", "FuncCall pg_catalog.pg_collation_for written in SQL syntax"],
    "SIMILAR TO" => ["SELECT x FROM t WHERE x SIMILAR TO 'a'", "A_Expr AEXPR_SIMILAR"],
    "NOT SIMILAR TO" => ["SELECT x FROM t WHERE x NOT SIMILAR TO 'a'", "A_Expr AEXPR_SIMILAR"],
    "field selection" => ["SELECT (t).x FROM t", "A_Indirection other than array subscripts"],
    "field selection from a function" => ["SELECT (f(x)).y FROM t", "A_Indirection other than array subscripts"],
    "a star of a composite" => ["SELECT (t).* FROM t", "A_Indirection other than array subscripts"],
    "a subscript then a field" => ["SELECT (x[1]).y FROM t", "A_Indirection other than array subscripts"],
    "a field after a subscript" => ["SELECT (f(x))[1].y FROM t", "A_Indirection other than array subscripts"],
    "a subscript after a field" => ["SELECT (x).y[1] FROM t", "A_Indirection other than array subscripts"],
    "DEFAULT" => ["SELECT DEFAULT", "SetToDefault"],
    "MERGE_ACTION" => ["SELECT merge_action() FROM t", "MergeSupportFunc"]
  }.freeze

  describe "an unsupported query" do
    refused.each do |construct, (sql, detail)|
      it "refuses #{construct}, naming #{detail}" do
        expect { check(sql) }.to refusal(detail)
      end
    end

    it "refuses it anywhere in the query, however deep" do
      sql = "SELECT (SELECT max(y) FROM (WITH w AS (SELECT 1) SELECT * FROM w WHERE EXISTS " \
            "(SELECT 1 FROM t WHERE coalesce(x SIMILAR TO 'a', false))) q)"
      expect { check(sql) }.to refusal("A_Expr AEXPR_SIMILAR")
    end

    # The parser never makes these from SQL text, so each case edits a
    # parse of a supported query.
    it "refuses a subquery kind outside the list" do
      parse = PgQuery.parse("SELECT (SELECT 1)")
      parse.tree.stmts[0].stmt.select_stmt.target_list[0].res_target.val.sub_link.sub_link_type = :MULTIEXPR_SUBLINK
      expect { described_class.check!(parse) }.to refusal("SubLink MULTIEXPR_SUBLINK")
    end

    it "refuses a function call format outside the list" do
      parse = PgQuery.parse("SELECT f(1)")
      parse.tree.stmts[0].stmt.select_stmt.target_list[0].res_target.val.func_call.funcformat = :COERCE_IMPLICIT_CAST
      expect { described_class.check!(parse) }.to refusal("FuncCall written as COERCE_IMPLICIT_CAST")
    end
  end

  describe "the error" do
    let(:sentinel) { "QUAACK_SENTINEL_3b9d" }

    # Raised while another error is being handled, the error would take
    # that one as its cause unless it's cleared. A caller's error can
    # quote SQL.
    it "has no cause, even when raised in a rescue" do
      errors = ["SELECT ROW(1)", "SELECT 1 WHERE 'a' SIMILAR TO 'b'"].map do |sql|
        raise "outer #{sentinel}"
      rescue RuntimeError
        begin
          check(sql)
          nil
        rescue described_class::Error => e
          e
        end
      end

      expect(errors.map(&:message))
        .to eq(["unsupported_construct: RowExpr", "unsupported_construct: A_Expr AEXPR_SIMILAR"])
      errors.each do |error|
        expect(error.cause).to be_nil
        expect(error.full_message).not_to include(sentinel)
      end
    end

    it "never quotes the query" do
      sqls = [
        "SELECT x FROM t WHERE x SIMILAR TO '#{sentinel}'",
        "SELECT * FROM t TABLESAMPLE system (1) WHERE x = '#{sentinel}'",
        "SELECT json_value('#{sentinel}', '$.#{sentinel}')",
        "SELECT (ROW('#{sentinel}')).f1",
        "SELECT '#{sentinel}'; SELECT '#{sentinel}'",
        "UPDATE t SET x = '#{sentinel}'",
        "SELECT * FROM ROWS FROM (f('#{sentinel}'), g('#{sentinel}')) r"
      ]
      errors = sqls.map do |sql|
        # The sentinel is really in what check! reads.
        expect(PgQuery.parse(sql).tree.to_json).to include(sentinel)
        check(sql)
        nil
      rescue described_class::Error => e
        e
      end

      expect(errors).to all(be_a(described_class::Error))
      errors.each do |error|
        expect(error.message).not_to include(sentinel)
        expect(error.full_message).not_to include(sentinel)
      end
    end
  end
end
