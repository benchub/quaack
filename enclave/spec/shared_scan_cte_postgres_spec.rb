# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/literals"
require "quaack/enclave/rewrite_rules/shared_scan_cte"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' shared_scan_cte, on a real server: a table read more than
# once in one FROM is read once, by a MATERIALIZED CTE of the
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
        (8, 2, 2, 'submitted', 4),
        (9, 1, 99, 'submitted', 1),
        (10, 2, 2, 'SUBMITTED', 3),
        (11, 1, 1, 'submitted', 1);
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
       "A table read more than once in one FROM is read once, by a MATERIALIZED CTE of the WHERE and " \
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

  it "leaves a lone copy in a subquery or CTE alone, and adds to a WITH the query has" do
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

  describe "with copies in a subquery or a CTE body" do
    let(:inner) do
      "FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
        "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2) AND s.user_id = u.id"
    end

    it "shares in a correlated subquery, keeping the conjuncts that read the outer query where they were" do
      expect_rewrites(
        "SELECT u.id FROM public.users u WHERE EXISTS (SELECT 1 FROM public.submissions s " \
        "JOIN public.submissions a ON a.id = s.assessor_asset_id WHERE s.course_id IN (1, 2) " \
        "AND a.course_id IN (1, 2) AND s.user_id = u.id AND a.user_id = u.id AND a.workflow_state IS NOT NULL)",
        "SELECT u.id FROM public.users u WHERE EXISTS (WITH quaack_scan_of_submissions AS MATERIALIZED " \
        "(SELECT * FROM public.submissions WHERE submissions.course_id IN ($2, $3)) " \
        "SELECT $1 FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a " \
        "ON a.id = s.assessor_asset_id WHERE s.user_id = u.id AND a.user_id = u.id AND a.workflow_state IS NOT NULL)"
      )
    end

    it "shares in a FROM subquery and in a CTE body" do
      body = "SELECT s.id AS sid, a.id AS aid FROM public.submissions s JOIN public.submissions a " \
             "ON a.id = s.assessor_asset_id WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2)"
      shared = "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
               "WHERE submissions.course_id IN ($1, $2)) SELECT s.id AS sid, a.id AS aid " \
               "FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a ON a.id = s.assessor_asset_id"
      expect_rewrites("SELECT x.sid, x.aid FROM (#{body}) x", "SELECT x.sid, x.aid FROM (#{shared}) x")
      expect_rewrites("WITH w AS (#{body}) SELECT w.sid FROM w", "WITH w AS (#{shared}) SELECT w.sid FROM w")
    end

    it "makes a rewrite for the outer query and one for each subquery, whatever aliases they reuse" do
      sql = "SELECT s.id FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
            "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2) AND s.id IN " \
            "(SELECT s.id FROM public.users u JOIN public.submissions s ON s.user_id = u.id " \
            "JOIN public.submissions a ON a.id = s.assessor_asset_id " \
            "WHERE s.workflow_state IS NOT NULL AND a.workflow_state IS NOT NULL)"
      outer, inner = rewritten(sql)

      expect(outer).to start_with("WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
                                  "WHERE submissions.course_id IN ($1, $2)) " \
                                  "SELECT s.id FROM quaack_scan_of_submissions s")
      expect(outer).to include("(SELECT s.id FROM public.users u JOIN public.submissions s")
      expect(inner).to include("AND s.id IN (WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM " \
                               "public.submissions WHERE submissions.workflow_state IS NOT NULL)")
      expect(inner).to start_with("SELECT s.id FROM public.submissions s JOIN public.submissions a")
      want = runs(sql)
      expect(want).not_to be_empty
      map = redacted(sql).placeholder_map
      expect([rows(outer, map), rows(inner, map)]).to eq([want, want])
    end

    it "leaves a branch of a set operation alone, and shares in a subquery inside one" do
      branch = "SELECT s.id FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
               "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2)"
      expect_refusals("SELECT 1 UNION #{branch}" => branch, "#{branch} UNION SELECT 1" => branch)
      expect(rewritten("WITH RECURSIVE r AS (#{branch} UNION ALL SELECT r.id FROM r WHERE false) SELECT r.id FROM r"))
        .to eq([])
      expect(rewritten("SELECT 1 UNION SELECT u.id FROM public.users u WHERE EXISTS (#{branch})").size).to eq(1)
    end

    it "refuses a copy in a subquery that reads a copy's whole row, and one whose CTE name is taken" do
      expect_refusals(
        "SELECT u.id FROM public.users u WHERE EXISTS (SELECT to_json(s) #{inner})" =>
          "SELECT u.id FROM public.users u WHERE EXISTS (SELECT s.id #{inner})",
        "WITH quaack_scan_of_submissions AS (SELECT 1) SELECT u.id FROM public.users u " \
        "WHERE EXISTS (SELECT 1 #{inner})" =>
          "WITH other AS (SELECT 1) SELECT u.id FROM public.users u WHERE EXISTS (SELECT 1 #{inner})"
      )
    end
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

  it "shares the copies not on a nullable side, and leaves a nullable copy reading the table", :aggregate_failures do
    from = "FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
           "LEFT JOIN public.submissions n ON n.id = s.user_id AND n.workflow_state = 'graded' " \
           "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2) AND (n.course_id IN (1, 2) OR n.id IS NULL)"
    expect_rewrites(
      "SELECT s.id, a.id, n.id #{from}",
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($2, $3)) " \
      "SELECT s.id, a.id, n.id FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a " \
      "ON a.id = s.assessor_asset_id LEFT JOIN public.submissions n " \
      "ON n.id = s.user_id AND n.workflow_state = $1 WHERE n.course_id IN ($6, $7) OR n.id IS NULL"
    )
    # A nullable copy's WHERE conjunct filters out the rows the outer join
    # null-extends, so it can't go in the CTE, and it isn't the other
    # copies' to share.
    sql = "SELECT s.id, a.id, n.id FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
          "LEFT JOIN public.submissions n ON n.id = s.user_id " \
          "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2) AND n.course_id IN (1, 2)"
    expect_rewrites(
      sql,
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
      "WHERE submissions.course_id IN ($1, $2)) " \
      "SELECT s.id, a.id, n.id FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a " \
      "ON a.id = s.assessor_asset_id LEFT JOIN public.submissions n ON n.id = s.user_id " \
      "WHERE n.course_id IN ($5, $6)"
    )
    wrong = "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
            "WHERE submissions.course_id IN ($1, $2)) " \
            "SELECT s.id, a.id, n.id FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a " \
            "ON a.id = s.assessor_asset_id LEFT JOIN quaack_scan_of_submissions n ON n.id = s.user_id"
    expect(rows(wrong, redacted(sql).placeholder_map)).not_to eq(runs(sql))
    expect(rewritten(sql.sub("s JOIN public.submissions a", "s LEFT JOIN public.submissions a"))).to eq([])
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
        "#{body} AND EXISTS (WITH other AS (SELECT 1) SELECT 1 FROM other)",
      "WITH w AS (WITH quaack_scan_of_submissions AS (SELECT 1 AS id) SELECT id FROM quaack_scan_of_submissions) " \
      "#{body}" => "WITH w AS (WITH other AS (SELECT 1 AS id) SELECT id FROM other) #{body}"
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

  it "reads no ON of an aliased join, whatever else it refuses" do
    top = PgQuery.parse(
      "SELECT 1 FROM public.users u JOIN (public.submissions s JOIN public.submissions a ON a.id = s.id) AS j " \
      "ON j.id = u.id JOIN public.users v ON v.id = u.id WHERE true"
    ).tree.stmts.first.stmt.select_stmt

    places = rule.send(:places, top)

    expect(places.size).to eq(3)
    refs = places.flat_map(&:conditions).flat_map { Quaack::Enclave::RewriteRules::Tree.find(it, PgQuery::ColumnRef) }
    expect(refs.filter_map { Quaack::Enclave::RewriteRules::Tree.qualified(it)&.first }.uniq).to eq(%w[j u v])
  end

  describe "with inheritance" do
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.places (id int, ref int, kind text);
        CREATE TABLE public.places_child () INHERITS (public.places);
        INSERT INTO public.places VALUES (1, 2, 'a'), (2, 1, 'a'), (3, NULL, 'a'), (4, 4, 'b'), (2, 3, 'a'), (7, 4, 'a'), (8, 7, 'a');
        INSERT INTO public.places_child VALUES (1, 4, 'a'), (5, 1, 'a'), (6, 6, 'b'), (4, 1, NULL);
      SQL
    end

    let(:only) do
      "SELECT p.id, q.id FROM ONLY public.places p JOIN ONLY public.places q ON q.id = p.ref " \
        "WHERE p.kind IN ('a', 'b') AND q.kind IN ('a', 'b')"
    end

    it "shares copies that read ONLY the table, in a CTE that reads ONLY it, and keeps the child rows out" do
      expect_rewrites(
        only,
        "WITH quaack_scan_of_places AS MATERIALIZED (SELECT * FROM ONLY public.places " \
        "WHERE places.kind IN ($1, $2)) " \
        "SELECT p.id, q.id FROM quaack_scan_of_places p JOIN quaack_scan_of_places q ON q.id = p.ref"
      )
      expect(runs(only)).not_to eq(runs(only.gsub("ONLY ", "")))
    end

    it "shares copies that read the children too, and doesn't mix them with the ONLY copies", :aggregate_failures do
      all = only.gsub("ONLY ", "")
      expect_rewrites(
        all,
        "WITH quaack_scan_of_places AS MATERIALIZED (SELECT * FROM public.places " \
        "WHERE places.kind IN ($1, $2)) " \
        "SELECT p.id, q.id FROM quaack_scan_of_places p JOIN quaack_scan_of_places q ON q.id = p.ref"
      )
      mixed = "SELECT p.id, q.id FROM ONLY public.places p JOIN public.places q ON q.id = p.ref " \
              "WHERE p.kind IN ('a', 'b') AND q.kind IN ('a', 'b')"
      expect(rewritten(mixed)).to eq([])
      expect(runs(mixed)).not_to eq(runs(only))
    end

    it "makes a rewrite for each group of one kind of copy" do
      sql = "SELECT p.id FROM ONLY public.places p, ONLY public.places q, public.places r, public.places s " \
            "WHERE p.kind = 'a' AND q.kind = 'a' AND r.kind = 'b' AND s.kind = 'b' AND q.id = p.ref " \
            "AND r.id = q.ref AND s.id = r.ref"
      expect_rewrites(
        sql,
        "WITH quaack_scan_of_places AS MATERIALIZED (SELECT * FROM ONLY public.places WHERE places.kind = $1) " \
        "SELECT p.id FROM quaack_scan_of_places p, quaack_scan_of_places q, public.places r, public.places s " \
        "WHERE r.kind = $3 AND s.kind = $4 AND q.id = p.ref AND r.id = q.ref AND s.id = r.ref",
        "WITH quaack_scan_of_places AS MATERIALIZED (SELECT * FROM public.places WHERE places.kind = $3) " \
        "SELECT p.id FROM ONLY public.places p, ONLY public.places q, quaack_scan_of_places r, " \
        "quaack_scan_of_places s WHERE p.kind = $1 AND q.kind = $2 AND q.id = p.ref AND r.id = q.ref " \
        "AND s.id = r.ref"
      )
    end
  end

  describe "with a GROUP BY that relies on the primary key" do
    let(:from) do
      "FROM public.submissions s JOIN public.submissions a ON a.id = s.assessor_asset_id " \
        "WHERE s.course_id IN (1, 2) AND a.course_id IN (1, 2)"
    end
    let(:cte) do
      "WITH quaack_scan_of_submissions AS MATERIALIZED (SELECT * FROM public.submissions " \
        "WHERE submissions.course_id IN ($1, $2)) "
    end
    let(:shared_from) do
      "FROM quaack_scan_of_submissions s JOIN quaack_scan_of_submissions a ON a.id = s.assessor_asset_id"
    end

    it "groups by the columns the query reads that the key stood in for, in the select list, HAVING, and ORDER BY" do
      expect_rewrites(
        "SELECT s.id, s.user_id, count(*) #{from} GROUP BY s.id HAVING s.workflow_state <> 'x' ORDER BY s.course_id",
        "#{cte}SELECT s.id, s.user_id, count(*) #{shared_from} GROUP BY s.id, s.user_id, s.workflow_state, " \
        "s.course_id HAVING s.workflow_state <> $5 ORDER BY s.course_id"
      )
    end

    it "groups by every column of a copy listed as copy.*, and by a column a subquery reads" do
      expect_rewrites(
        "SELECT s.*, (SELECT max(u.id) FROM public.users u WHERE u.id = a.user_id) AS m, count(a.id) #{from} " \
        "GROUP BY s.id, a.id",
        "#{cte}SELECT s.*, (SELECT max(u.id) FROM public.users u WHERE u.id = a.user_id) AS m, count(a.id) " \
        "#{shared_from} GROUP BY s.id, a.id, s.course_id, s.user_id, s.workflow_state, s.assessor_asset_id, " \
        "a.user_id"
      )
    end

    it "does the same for every copy whose key is grouped" do
      expect_rewrites(
        "SELECT s.id, s.user_id, a.id, a.user_id #{from} GROUP BY s.id, a.id",
        "#{cte}SELECT s.id, s.user_id, a.id, a.user_id #{shared_from} GROUP BY s.id, a.id, s.user_id, a.user_id"
      )
    end

    it "leaves a GROUP BY that doesn't hold the whole key alone, as a column expression's own is" do
      expect_rewrites(
        "SELECT lower(s.workflow_state), count(*) #{from} GROUP BY lower(s.workflow_state)",
        "#{cte}SELECT lower(s.workflow_state), count(*) #{shared_from} GROUP BY lower(s.workflow_state)"
      )
      # Adding the column the expression reads would split its groups.
      sql = "SELECT lower(s.workflow_state), count(*) #{from} GROUP BY lower(s.workflow_state)"
      wrong = "#{cte}SELECT lower(s.workflow_state), count(*) #{shared_from} GROUP BY lower(s.workflow_state), " \
              "s.workflow_state"
      expect(rows(wrong, redacted(sql).placeholder_map)).not_to eq(runs(sql))
    end

    # SupportedSql refuses grouping sets before any rule runs, so this asks the step itself.
    it "adds nothing to grouping sets" do
      top = PgQuery.parse(
        "SELECT s.id, s.user_id, s.workflow_state, count(*) #{from} GROUP BY s.id, ROLLUP (s.user_id)"
      ).tree.stmts.first.stmt.select_stmt
      copies = Quaack::Enclave::RewriteRules::Tree.from_items(top.from_clause)
      before = top.group_clause.map { PgQuery::Node.encode(it) }

      rule.send(:group_by_columns!, top, copies, %w[public submissions true], catalog)
      expect(top.group_clause.map { PgQuery::Node.encode(it) }).to eq(before)
    end

    it "groups by a composite key's other columns only when the whole key is grouped" do
      conn.exec(<<~SQL)
        CREATE TABLE public.pairs (x int, y int, v text, PRIMARY KEY (x, y));
        INSERT INTO public.pairs VALUES (1, 1, 'a'), (1, 2, 'A'), (2, 1, NULL), (2, 2, 'a'), (3, 1, 'c');
      SQL
      pairs = "FROM public.pairs p JOIN public.pairs q ON q.x = p.y WHERE p.x IN (1, 2) AND q.x IN (1, 2)"
      expect_rewrites(
        "SELECT p.x, p.y, p.v, count(*) #{pairs} GROUP BY p.x, p.y",
        "WITH quaack_scan_of_pairs AS MATERIALIZED (SELECT * FROM public.pairs WHERE pairs.x IN ($1, $2)) " \
        "SELECT p.x, p.y, p.v, count(*) FROM quaack_scan_of_pairs p JOIN quaack_scan_of_pairs q ON q.x = p.y " \
        "GROUP BY p.x, p.y, p.v"
      )
      # With part of the key grouped, a column an expression reads must stay out, as it would split the groups.
      sql = "SELECT p.x, lower(p.v), count(*) #{pairs} GROUP BY p.x, lower(p.v)"
      expect_rewrites(
        sql,
        "WITH quaack_scan_of_pairs AS MATERIALIZED (SELECT * FROM public.pairs WHERE pairs.x IN ($1, $2)) " \
        "SELECT p.x, lower(p.v), count(*) FROM quaack_scan_of_pairs p JOIN quaack_scan_of_pairs q ON q.x = p.y " \
        "GROUP BY p.x, lower(p.v)"
      )
    end

    it "adds a column a nested subquery's own copy of the alias reads, which splits no group" do
      expect_rewrites(
        "SELECT s.id, (SELECT max(s.user_id) FROM public.submissions s WHERE s.id = 1) AS m, count(*) #{from} " \
        "GROUP BY s.id",
        "#{cte.sub("$1, $2", "$2, $3")}SELECT s.id, " \
        "(SELECT max(s.user_id) FROM public.submissions s WHERE s.id = $1) AS m, count(*) " \
        "#{shared_from} GROUP BY s.id, s.user_id"
      )
    end

    it "refuses when inheritance children can repeat the key" do
      conn.exec(<<~SQL)
        CREATE TABLE public.kids (id int PRIMARY KEY, v text);
        CREATE TABLE public.kids_child () INHERITS (public.kids);
        INSERT INTO public.kids VALUES (1, 'a'), (2, 'b');
        INSERT INTO public.kids_child VALUES (1, 'c'), (2, 'b');
      SQL
      kids = "FROM public.kids k JOIN public.kids j ON j.id = k.id WHERE k.id IN (1, 2) AND j.id IN (1, 2)"
      expect_refusals("SELECT k.id, k.v, count(*) #{kids} GROUP BY k.id" =>
                        "SELECT k.id, k.v, count(*) #{kids} GROUP BY k.id, k.v")
    end
  end

  it "needs two copies in one FROM, not one in the query and one in a subquery" do
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

  it "refuses a set operation and an unnamed FROM item", :aggregate_failures do
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
        "AND x.course_id IN (1, 2)) CROSS JOIN #{from.delete_prefix("FROM ")}"
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
