# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/literals"
require "quaack/enclave/rewrite_rules/shared_scan_cte"
require_relative "support/production_server"

# DESIGN.md 6c's shared_scan_cte, on a real server: a table read more than
# once in the top-level FROM is read once, by a MATERIALIZED CTE of the
# conjuncts every copy shares, and every rewrite returns the original's rows.
RSpec.describe Quaack::Enclave::RewriteRules::SharedScanCte do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.submissions (
        id int PRIMARY KEY, course_id int, user_id int, workflow_state text, assessor_asset_id int
      );
      CREATE TABLE public.users (id int PRIMARY KEY, name text);
      INSERT INTO public.submissions VALUES
        (1, 1, 1, 'submitted', 2),
        (2, 1, 2, 'deleted', 3),
        (3, 2, 1, 'graded', 2),
        (4, 2, 3, 'deleted', 2),
        (5, 3, 1, 'submitted', 1),
        (6, NULL, 2, NULL, 1),
        (7, 1, NULL, 'submitted', NULL),
        (8, 2, 2, 'submitted', 4);
      INSERT INTO public.users VALUES (1, 'a'), (2, 'b'), (3, NULL);
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  def literals_for(sql)
    redacted = redacted(sql)
    literals = Quaack::Enclave::RewriteRules::Literals.new(conn, redacted.placeholder_map)
    [redacted.sql, literals]
  end

  def rewritten(sql)
    redacted, literals = literals_for(sql)
    rule.rewrites(PgQuery.parse(redacted), catalog, literals).map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  def rows(sql, map)
    name = "quaack_rule_spec"
    binding = Quaack::Enclave::Redaction.binding(sql, map)
    binding.prepare(conn, name)
    binding.execute(conn, name).values.sort_by(&:to_s)
  ensure
    begin
      conn.exec("DEALLOCATE #{name}")
    rescue StandardError
      nil
    end
  end

  # The rewrites of sql are exactly expected, and each returns sql's rows,
  # which aren't empty.
  def expect_rewrites(sql, *expected)
    expect(rewritten(sql)).to eq(expected)
    want = runs(sql)
    expect(want).not_to be_empty
    map = redacted(sql).placeholder_map
    expected.each { expect(rows(it, map)).to eq(want) }
  end

  def runs(sql)
    original = redacted(sql)
    rows(original.sql, original.placeholder_map)
  end

  # Each refused query, which Postgres runs, makes no rewrite, and its
  # twin, the same query without what it refuses, makes one.
  def expect_refusals(cases)
    cases.each do |refused, twin|
      expect { runs(refused) }.not_to raise_error, refused
      expect(rewritten(refused)).to eq([]), refused
      expect(rewritten(twin).size).to eq(1), twin
    end
  end

  let(:canvas) do
    "SELECT submissions.id, assessor_asset.id FROM public.submissions " \
      "JOIN public.submissions AS assessor_asset ON assessor_asset.id = submissions.assessor_asset_id " \
      "WHERE submissions.course_id IN (1, 2) AND assessor_asset.course_id IN (1, 2) " \
      "AND submissions.workflow_state <> 'deleted'"
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["shared_scan_cte",
       "A table read more than once in the top-level FROM is read once, by a MATERIALIZED CTE of the WHERE and " \
       "inner-join ON conjuncts every copy shares."]
    )
  end

  it "moves the conjuncts every copy shares into the CTE, and leaves a conjunct only one copy has on that copy" do
    expect_rewrites(
      canvas,
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($1, $2)) " \
      "SELECT submissions.id, assessor_asset.id FROM quaack_scan_of_submissions submissions " \
      "JOIN quaack_scan_of_submissions assessor_asset ON assessor_asset.id = submissions.assessor_asset_id " \
      "WHERE submissions.workflow_state <> $5"
    )
  end

  it "counts inner-join ON conjuncts, and leaves the copy's other ON conjuncts in that ON" do
    expect_rewrites(
      "SELECT s.id, a.id FROM public.submissions s JOIN public.submissions a " \
      "ON a.course_id IN (1, 2) AND a.user_id = s.user_id WHERE s.course_id IN (1, 2)",
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($3, $4)) " \
      "SELECT s.id, a.id FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a " \
      "ON a.user_id = s.user_id"
    )
  end

  it "leaves ON true for an ON that held only shared conjuncts" do
    expect_rewrites(
      "SELECT s.id, a.id FROM public.submissions s JOIN public.submissions a ON a.course_id IN (1, 2) " \
      "WHERE s.course_id IN (1, 2) AND a.user_id = s.user_id",
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($3, $4)) " \
      "SELECT s.id, a.id FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a ON true " \
      "WHERE a.user_id = s.user_id"
    )
  end

  it "leaves another table's conjunct that reads the same as a shared one" do
    expect_rewrites(
      "SELECT s.id FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
      "JOIN public.users u ON u.id = s.user_id WHERE s.id IN (1, 2) AND a.id IN (1, 2) AND u.id IN (1, 2)",
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.id IN ($1, $2)) " \
      "SELECT s.id FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a " \
      "ON a.id = s.assessor_asset_id JOIN public.users u ON u.id = s.user_id WHERE u.id IN ($5, $6)"
    )
  end

  it "leaves a join with no ON as it was" do
    expect_rewrites(
      "SELECT s.id, a.id FROM public.submissions s CROSS JOIN public.submissions a " \
      "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2) AND a.user_id = s.user_id",
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($1, $2)) " \
      "SELECT s.id, a.id FROM quaack_scan_of_submissions s CROSS JOIN quaack_scan_of_submissions a " \
      "WHERE a.user_id = s.user_id"
    )
  end

  it "moves every shared conjunct, in the first copy's order, whatever order the others have them in" do
    expect_rewrites(
      "SELECT s.course_id, a.course_id FROM public.submissions s, public.submissions a " \
      "WHERE s.course_id IN (1, 2) AND s.workflow_state <> 'deleted' AND a.workflow_state <> 'deleted' " \
      "AND a.course_id IN (1, 2) AND a.user_id = s.user_id",
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($1, $2) AND submissions.workflow_state <> $3) " \
      "SELECT s.course_id, a.course_id FROM quaack_scan_of_submissions s, quaack_scan_of_submissions a " \
      "WHERE a.user_id = s.user_id"
    )
  end

  it "moves a conjunct a copy has twice once, and leaves a conjunct that reads no copy" do
    expect_rewrites(
      "SELECT s.id, a.id FROM public.submissions s JOIN public.submissions a " \
      "ON a.id = s.assessor_asset_id AND s.course_id IN (1, 2) " \
      "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2) AND 1 = 1",
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($3, $4)) " \
      "SELECT s.id, a.id FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a " \
      "ON a.id = s.assessor_asset_id WHERE $7 = $8"
    )
  end

  it "moves only what all of three copies share, keeps an unaliased copy's name, and keeps duplicate rows" do
    expect_rewrites(
      "SELECT submissions.user_id FROM public.submissions, public.submissions a, public.submissions b " \
      "WHERE submissions.course_id IN (1, 2) AND a.course_id IN (1, 2) AND b.course_id IN (1, 2) " \
      "AND submissions.workflow_state = 'submitted' AND a.workflow_state = 'submitted' " \
      "AND submissions.user_id = a.user_id AND a.id = b.id",
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($1, $2)) " \
      "SELECT submissions.user_id FROM quaack_scan_of_submissions submissions, quaack_scan_of_submissions a, " \
      "quaack_scan_of_submissions b WHERE submissions.workflow_state = $7 AND a.workflow_state = $8 " \
      "AND submissions.user_id = a.user_id AND a.id = b.id"
    )
  end

  it "keeps a copy's whole row in the select list as copy.*" do
    expect_rewrites(
      "SELECT s.*, a.id FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
      "WHERE s.workflow_state IS NOT NULL AND a.workflow_state IS NOT NULL",
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.workflow_state IS NOT NULL) " \
      "SELECT s.*, a.id FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a " \
      "ON a.id = s.assessor_asset_id"
    )
  end

  it "makes one rewrite for each table read more than once" do
    expect_rewrites(
      "SELECT s.id, u.name FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
      "JOIN public.users u ON u.id = s.user_id JOIN public.users v ON v.id = a.user_id " \
      "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2) AND u.name IS NOT NULL AND v.name IS NOT NULL",
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($1, $2)) " \
      "SELECT s.id, u.name FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a " \
      "ON a.id = s.assessor_asset_id JOIN public.users u ON u.id = s.user_id JOIN public.users v ON v.id = a.user_id " \
      "WHERE u.name IS NOT NULL AND v.name IS NOT NULL",
      "WITH quaack_scan_of_users AS MATERIALIZED (SELECT * FROM public.users WHERE users.name IS NOT NULL) " \
      "SELECT s.id, u.name FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
      "JOIN quaack_scan_of_users u ON u.id = s.user_id JOIN quaack_scan_of_users v ON v.id = a.user_id " \
      "WHERE s.course_id IN ($1, $2) AND a.course_id IN ($3, $4)"
    )
  end

  it "leaves a copy in a subquery reading the table, and adds to a WITH the query has" do
    expect_rewrites(
      "WITH graded AS (SELECT g.id FROM public.submissions g WHERE g.workflow_state = 'graded') " \
      "SELECT s.id FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
      "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2) " \
      "AND NOT EXISTS (SELECT 1 FROM public.submissions x WHERE x.id = s.user_id AND x.workflow_state = 'deleted') " \
      "AND s.id NOT IN (SELECT graded.id FROM graded)",
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($2, $3)), " \
      "graded AS (SELECT g.id FROM public.submissions g WHERE g.workflow_state = $1) " \
      "SELECT s.id FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a " \
      "ON a.id = s.assessor_asset_id " \
      "WHERE NOT EXISTS (SELECT $6 FROM public.submissions x WHERE x.id = s.user_id AND x.workflow_state = $7) " \
      "AND NOT s.id IN (SELECT graded.id FROM graded)"
    )
  end

  it "accepts a name as long as Postgres keeps, and refuses a longer one", :aggregate_failures do
    kept = "t" * 48
    cut = "t" * 49
    conn.exec("CREATE TABLE public.#{kept} (id int, k int); INSERT INTO public.#{kept} VALUES (1, 1)")
    conn.exec("CREATE TABLE public.#{cut} (id int, k int); INSERT INTO public.#{cut} VALUES (1, 1)")
    expect_refusals(
      "SELECT x.id FROM public.#{cut} x, public.#{cut} y WHERE x.k = 1 AND y.k = 1" =>
        "SELECT x.id FROM public.#{kept} x, public.#{kept} y WHERE x.k = 1 AND y.k = 1"
    )
  end

  it "refuses a copy on an outer join's nullable side", :aggregate_failures do
    twin = "SELECT s.id FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
           "WHERE (s.course_id IN (1, 2)) IS NOT FALSE AND (a.course_id IN (1, 2)) IS NOT FALSE"
    expect_refusals(
      twin.sub("JOIN", "LEFT JOIN") => twin,
      twin.sub("JOIN", "RIGHT JOIN") => twin,
      twin.sub("JOIN", "FULL JOIN") => twin,
      "SELECT u.id FROM public.users u LEFT JOIN (public.submissions s JOIN public.submissions a " \
      "ON a.id = s.assessor_asset_id AND a.course_id IN (1, 2) AND s.course_id IN (1, 2)) ON u.id = s.user_id" =>
        "SELECT u.id FROM public.users u JOIN (public.submissions s JOIN public.submissions a " \
        "ON a.id = s.assessor_asset_id AND a.course_id IN (1, 2) AND s.course_id IN (1, 2)) ON u.id = s.user_id"
    )
  end

  it "doesn't count an outer join's ON conjuncts" do
    twin = "SELECT s.id FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
           "JOIN public.users u ON u.id = s.user_id AND s.course_id IN (1, 2) AND a.course_id IN (1, 2)"
    expect_refusals(twin.sub("JOIN public.users", "LEFT JOIN public.users") => twin)
  end

  it "shares only conjuncts that each read one copy, with the same literals, and no subquery", :aggregate_failures do
    base = "SELECT s.id FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id WHERE "
    expect_refusals(
      "#{base}s.course_id IN (1, 2) AND a.course_id IN (1, 3)" =>
        "#{base}s.course_id IN (1, 2) AND a.course_id IN (1, 2)",
      "#{base}s.course_id = a.course_id AND a.user_id = s.user_id" =>
        "#{base}s.course_id = a.course_id AND s.user_id = 1 AND a.user_id = 1",
      "#{base}s.id IN (SELECT s.assessor_asset_id FROM public.submissions) " \
      "AND a.id IN (SELECT a.assessor_asset_id FROM public.submissions)" =>
        "#{base}s.id = s.assessor_asset_id AND a.id = a.assessor_asset_id",
      "#{base}s.course_id IN (1, 2)" => "#{base}s.course_id IN (1, 2) AND a.course_id IN (1, 2)"
    )
  end

  it "refuses a shared conjunct that calls a volatile function" do
    base = "SELECT s.id FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id WHERE "
    expect_refusals("#{base}s.user_id < random() * 10 AND a.user_id < random() * 10" =>
                      "#{base}s.user_id < abs(10) AND a.user_id < abs(10)")
  end

  it "refuses a query that already has a CTE of the name, at any depth", :aggregate_failures do
    body = "SELECT s.id FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
           "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2)"
    expect_refusals(
      "WITH quaack_scan_of_submissions AS (SELECT 1) #{body}" => "WITH other AS (SELECT 1) #{body}",
      "#{body} AND EXISTS (WITH quaack_scan_of_submissions AS (SELECT 1) SELECT 1 FROM quaack_scan_of_submissions)" =>
        "#{body} AND EXISTS (WITH other AS (SELECT 1) SELECT 1 FROM other)"
    )
  end

  it "shares only plain tables: not a CTE, and not a copy that renames columns", :aggregate_failures do
    from = "public.submissions s, public.submissions a WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2) " \
           "AND a.id = s.assessor_asset_id"
    expect_refusals(
      "WITH x AS MATERIALIZED (SELECT * FROM public.submissions) " \
      "SELECT s.id FROM #{from.gsub("public.submissions", "x")}" =>
        "WITH x AS MATERIALIZED (SELECT * FROM public.submissions) SELECT s.id FROM #{from}",
      "SELECT s.id FROM #{from.sub("submissions s", "submissions s(course_id, id)")}" => "SELECT s.id FROM #{from}"
    )
  end

  it "needs two copies in the top-level FROM" do
    expect_refusals(
      "SELECT s.id FROM public.submissions s WHERE s.course_id IN (1, 2) " \
      "AND s.id IN (SELECT a.id FROM public.submissions a WHERE a.course_id IN (1, 2))" =>
        "SELECT s.id FROM public.submissions s, public.submissions a WHERE s.course_id IN (1, 2) " \
        "AND s.id = a.id AND a.course_id IN (1, 2)"
    )
  end

  it "refuses what a CTE can't stand in for: system columns, whole rows, and long column names",
     :aggregate_failures do
    from = "FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
           "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2)"
    expect_refusals(
      "SELECT s.ctid #{from}" => "SELECT s.id #{from}",
      "SELECT s.id #{from} AND a.xmin IS NOT NULL" => "SELECT s.id #{from} AND a.id IS NOT NULL",
      "SELECT a.tableoid #{from}" => "SELECT a.id #{from}",
      "SELECT to_json(s) #{from}" => "SELECT to_json(s.id) #{from}",
      "SELECT s.id AS x #{from} ORDER BY a" => "SELECT s.id AS x #{from} ORDER BY x",
      "SELECT row_to_json(s.*) #{from}" => "SELECT s.* #{from}",
      "SELECT count(a.*) #{from}" => "SELECT count(a.id) #{from}",
      "SELECT public.submissions.id FROM public.submissions JOIN public.submissions a " \
      "ON a.id = submissions.assessor_asset_id WHERE submissions.course_id IN (1, 2) AND a.course_id IN (1, 2)" =>
        "SELECT submissions.id FROM public.submissions JOIN public.submissions a " \
        "ON a.id = submissions.assessor_asset_id WHERE submissions.course_id IN (1, 2) AND a.course_id IN (1, 2)"
    )
  end

  it "refuses a set operation, an unnamed FROM item, and a rewrite that won't prepare", :aggregate_failures do
    from = "FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
           "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2)"
    expect_refusals(
      "SELECT s.id #{from} UNION SELECT 1" => "SELECT s.id #{from}",
      "SELECT 1 FROM (public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
      "AND s.course_id IN (1, 2) AND a.course_id IN (1, 2)) AS j" =>
        "SELECT 1 FROM (public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
        "AND s.course_id IN (1, 2) AND a.course_id IN (1, 2))",
      "SELECT s.id FROM (public.submissions s JOIN public.users u ON u.id = s.user_id " \
      "AND s.course_id IN (1, 2)) AS j CROSS JOIN #{from.delete_prefix("FROM ")}" =>
        "SELECT s.id FROM (public.submissions x JOIN public.users u ON u.id = x.user_id " \
        "AND x.course_id IN (1, 2)) CROSS JOIN #{from.delete_prefix("FROM ")}",
      "SELECT s.id, s.user_id, count(*) #{from} GROUP BY s.id" =>
        "SELECT s.id, s.user_id, count(*) #{from} GROUP BY s.id, s.user_id"
    )
  end

  it "chains after transitive_predicate_copy, which makes the conjunct the copies share" do
    sql = "SELECT s.id FROM public.submissions s JOIN public.submissions a ON a.course_id = s.course_id " \
          "WHERE s.course_id IN (1, 2)"
    redacted, literals = literals_for(sql)
    generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(redacted), catalog, literals)
    chained = generated.rewrites.find { it.rules.map(&:name) == %w[transitive_predicate_copy shared_scan_cte] }

    expect(chained&.sql).to eq(
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($1, $2)) " \
      "SELECT s.id FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a ON a.course_id = s.course_id"
    )
    original = redacted(sql)
    expect(rows(chained.sql, original.placeholder_map)).to eq(rows(original.sql, original.placeholder_map))
  end

  it "makes no rewrite without the literals oracle" do
    redacted, = literals_for(canvas)

    expect(rule.rewrites(PgQuery.parse(redacted), catalog, nil)).to eq([])
  end

  it "doesn't change the parse it was given" do
    redacted, literals = literals_for(canvas)
    parse = PgQuery.parse(redacted)
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

    expect(rule.rewrites(parse, catalog, literals).size).to eq(1)
    expect(parse.tree).to eq(before)
  end
end
