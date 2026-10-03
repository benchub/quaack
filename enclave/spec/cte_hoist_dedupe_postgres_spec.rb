# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/cte_hoist_dedupe"
require "quaack/enclave/rewrite_rules/literals"
require_relative "support/production_server"

# DESIGN.md 6c's cte_hoist_dedupe, on a real server: CTEs whose bodies match,
# at any depth, become one CTE in the top-level WITH that every reference
# reads, and every rewrite returns the original's rows.
RSpec.describe Quaack::Enclave::RewriteRules::CteHoistDedupe do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # The body most tests repeat, with its account as a literal.
  def body(account = 1) = "SELECT user_id FROM public.user_account_associations WHERE account_id = #{account}"

  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.users (id int PRIMARY KEY, name text, workflow_state text);
      CREATE TABLE public.user_account_associations (id int PRIMARY KEY, user_id int, account_id int);
      INSERT INTO public.users VALUES
        (1, 'a', 'active'), (2, 'b', 'deleted'), (3, NULL, 'active'), (4, 'd', NULL), (5, 'a', 'active'),
        (6, 'a', 'deleted');
      INSERT INTO public.user_account_associations VALUES
        (1, 1, 1), (2, 1, 1), (3, 2, 1), (4, 3, 1), (5, NULL, 1), (6, 4, 2), (7, 5, NULL), (8, 3, 2), (9, 6, 1);
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  def literals_for(sql)
    redacted = redacted(sql)
    literals = Quaack::Enclave::RewriteRules::Literals.new(conn, redacted.placeholder_map,
                                                           redacted.placeholder_shapes)
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

  # The rewrite of sql is exactly expected, and returns sql's rows, which
  # aren't empty.
  def expect_rewrite(sql, expected)
    expect(rewritten(sql)).to eq([expected])
    original = redacted(sql)
    want = rows(original.sql, original.placeholder_map)
    expect(want).not_to be_empty
    expect(rows(expected, original.placeholder_map)).to eq(want)
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["cte_hoist_dedupe",
       "CTEs with the same body, at any depth, become one CTE in the top-level WITH that every reference reads."]
    )
  end

  it "hoists the CTEs of a UNION's arms and the outer WHERE into one top-level CTE, keeping MATERIALIZED" do
    cte = "WITH users_in_account AS MATERIALIZED (#{body}) SELECT user_id FROM users_in_account"
    expect_rewrite(
      "SELECT u.id, u.name FROM (" \
      "SELECT users.id, users.name FROM public.users WHERE users.name = 'a' AND users.id IN (#{cte}) " \
      "UNION SELECT users.id, users.name FROM public.users " \
      "WHERE users.workflow_state = 'active' AND users.id IN (#{cte})) u WHERE u.id IN (#{cte})",
      "WITH users_in_account AS MATERIALIZED (SELECT user_id FROM public.user_account_associations " \
      "WHERE account_id = $2) SELECT u.id, u.name FROM (" \
      "SELECT users.id, users.name FROM public.users WHERE users.name = $1 AND users.id IN " \
      "(SELECT user_id FROM users_in_account) " \
      "UNION SELECT users.id, users.name FROM public.users " \
      "WHERE users.workflow_state = $3 AND users.id IN (SELECT user_id FROM users_in_account)) u " \
      "WHERE u.id IN (SELECT user_id FROM users_in_account)"
    )
  end

  it "merges NOT MATERIALIZED copies and plain copies, keeping each option" do
    expect_rewrite(
      "SELECT users.id FROM public.users " \
      "WHERE users.id IN (WITH n AS NOT MATERIALIZED (#{body}) SELECT user_id FROM n) " \
      "AND users.id IN (WITH n AS NOT MATERIALIZED (#{body}) SELECT user_id FROM n) " \
      "AND users.id IN (WITH p AS (#{body(2)}) SELECT user_id FROM p) " \
      "AND users.id IN (WITH p AS (#{body(2)}) SELECT user_id FROM p)",
      "WITH n AS NOT MATERIALIZED (SELECT user_id FROM public.user_account_associations WHERE account_id = $1), " \
      "p AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $3) " \
      "SELECT users.id FROM public.users WHERE users.id IN (SELECT user_id FROM n) " \
      "AND users.id IN (SELECT user_id FROM n) AND users.id IN (SELECT user_id FROM p) " \
      "AND users.id IN (SELECT user_id FROM p)"
    )
  end

  it "merges into a top-level copy, moved first, from any depth" do
    expect_rewrite(
      "WITH other AS (SELECT users.id FROM public.users WHERE users.id IN " \
      "(WITH a AS (#{body}) SELECT user_id FROM a)), a AS (#{body}) " \
      "SELECT other.id FROM other WHERE other.id IN (SELECT user_id FROM a) AND EXISTS (SELECT 1 FROM " \
      "(SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (#{body}) SELECT user_id FROM a)) s " \
      "WHERE s.id = other.id)",
      "WITH a AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $1), " \
      "other AS (SELECT users.id FROM public.users WHERE users.id IN (SELECT user_id FROM a)) " \
      "SELECT other.id FROM other WHERE other.id IN (SELECT user_id FROM a) AND EXISTS (SELECT $3 FROM " \
      "(SELECT users.id FROM public.users WHERE users.id IN (SELECT user_id FROM a)) s WHERE s.id = other.id)"
    )
  end

  it "merges copies under different names, aliasing each renamed reference by its old name" do
    expect_rewrite(
      "SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (#{body}) SELECT a.user_id FROM a) " \
      "AND users.id IN (WITH b AS (#{body}) SELECT b.user_id FROM b)",
      "WITH a AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $1) " \
      "SELECT users.id FROM public.users WHERE users.id IN (SELECT a.user_id FROM a) " \
      "AND users.id IN (SELECT b.user_id FROM a b)"
    )
  end

  it "renames the hoisted CTE quaack_cte_<n> when its name is used for something else" do
    expect_rewrite(
      "WITH a AS (SELECT users.id AS user_id FROM public.users WHERE users.workflow_state = 'active') " \
      "SELECT users.id FROM public.users WHERE users.id IN (SELECT a.user_id FROM a) " \
      "AND users.id IN (SELECT x.user_id FROM (WITH a AS (#{body}) SELECT a.user_id FROM a) x) " \
      "AND users.id IN (WITH a AS (#{body}) SELECT user_id FROM a)",
      "WITH quaack_cte_1 AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $2), " \
      "a AS (SELECT users.id AS user_id FROM public.users WHERE users.workflow_state = $1) " \
      "SELECT users.id FROM public.users WHERE users.id IN (SELECT a.user_id FROM a) " \
      "AND users.id IN (SELECT x.user_id FROM (SELECT a.user_id FROM quaack_cte_1 a) x) " \
      "AND users.id IN (SELECT user_id FROM quaack_cte_1 a)"
    )
  end

  it "doesn't redirect a reference that a nearer CTE of the same name hides" do
    expect_rewrite(
      "SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (#{body}) SELECT user_id FROM a) " \
      "AND users.id IN (WITH a AS (#{body}) SELECT user_id FROM a WHERE user_id IN " \
      "(WITH a AS (SELECT users.id AS user_id FROM public.users WHERE users.name = 'a') SELECT a.user_id FROM a))",
      "WITH quaack_cte_1 AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $1) " \
      "SELECT users.id FROM public.users WHERE users.id IN (SELECT user_id FROM quaack_cte_1 a) " \
      "AND users.id IN (SELECT user_id FROM quaack_cte_1 a WHERE user_id IN " \
      "(WITH a AS (SELECT users.id AS user_id FROM public.users WHERE users.name = $3) SELECT a.user_id FROM a))"
    )
  end

  it "renames the hoisted CTE when an unreferenced CTE has its name" do
    expect_rewrite(
      "WITH a AS (SELECT users.id AS user_id FROM public.users WHERE users.workflow_state = 'active') " \
      "SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (#{body}) SELECT user_id FROM a) " \
      "AND users.id IN (WITH a AS (#{body}) SELECT user_id FROM a)",
      "WITH quaack_cte_1 AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $2), " \
      "a AS (SELECT users.id AS user_id FROM public.users WHERE users.workflow_state = $1) " \
      "SELECT users.id FROM public.users WHERE users.id IN (SELECT user_id FROM quaack_cte_1 a) " \
      "AND users.id IN (SELECT user_id FROM quaack_cte_1 a)"
    )
  end

  it "renames the hoisted CTE when an unqualified table reference has its name" do
    expect_rewrite(
      "SELECT users.id FROM users WHERE users.id IN (WITH users AS (#{body}) SELECT user_id FROM users) " \
      "AND users.id IN (WITH users AS (#{body}) SELECT user_id FROM users)",
      "WITH quaack_cte_1 AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $1) " \
      "SELECT users.id FROM users WHERE users.id IN (SELECT user_id FROM quaack_cte_1 users) " \
      "AND users.id IN (SELECT user_id FROM quaack_cte_1 users)"
    )
  end

  it "skips a quaack_cte_<n> name a table has" do
    conn.exec("CREATE TABLE public.quaack_cte_1 (id int); INSERT INTO public.quaack_cte_1 VALUES (1), (2), (NULL)")
    expect_rewrite(
      "SELECT q.id FROM quaack_cte_1 q JOIN users ON users.id = q.id " \
      "WHERE q.id IN (WITH users AS (#{body}) SELECT user_id FROM users) " \
      "AND q.id IN (WITH users AS (#{body}) SELECT user_id FROM users)",
      "WITH quaack_cte_2 AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $1) " \
      "SELECT q.id FROM quaack_cte_1 q JOIN users ON users.id = q.id " \
      "WHERE q.id IN (SELECT user_id FROM quaack_cte_2 users) AND q.id IN (SELECT user_id FROM quaack_cte_2 users)"
    )
  end

  it "leaves a copy alone when its only matches are inside other copies that merge" do
    outer = "WITH o AS (WITH x AS (#{body}) SELECT user_id FROM x) SELECT user_id FROM o"
    expect_rewrite(
      "SELECT users.id FROM public.users WHERE users.id IN (#{outer}) AND users.id IN (#{outer}) " \
      "AND users.id IN (WITH x AS (#{body}) SELECT user_id FROM x)",
      "WITH o AS (WITH x AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $1) " \
      "SELECT user_id FROM x) SELECT users.id FROM public.users WHERE users.id IN (SELECT user_id FROM o) " \
      "AND users.id IN (SELECT user_id FROM o) " \
      "AND users.id IN (WITH x AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $3) " \
      "SELECT user_id FROM x)"
    )
  end

  it "skips a quaack_cte_<n> name the query already uses" do
    expect_rewrite(
      "WITH quaack_cte_1 AS (SELECT users.id FROM public.users), " \
      "a AS (SELECT users.id FROM public.users WHERE users.name IS NOT NULL) " \
      "SELECT quaack_cte_1.id FROM quaack_cte_1 WHERE quaack_cte_1.id IN (SELECT a.id FROM a) " \
      "AND quaack_cte_1.id IN (WITH a AS (#{body}) SELECT user_id FROM a) " \
      "AND quaack_cte_1.id IN (WITH a AS (#{body}) SELECT user_id FROM a)",
      "WITH quaack_cte_2 AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $1), " \
      "quaack_cte_1 AS (SELECT users.id FROM public.users), " \
      "a AS (SELECT users.id FROM public.users WHERE users.name IS NOT NULL) " \
      "SELECT quaack_cte_1.id FROM quaack_cte_1 WHERE quaack_cte_1.id IN (SELECT a.id FROM a) " \
      "AND quaack_cte_1.id IN (SELECT user_id FROM quaack_cte_2 a) " \
      "AND quaack_cte_1.id IN (SELECT user_id FROM quaack_cte_2 a)"
    )
  end

  it "hoists a CTE whose body has its own WITH whole, and leaves the inner one inside it" do
    inner = "WITH a AS (WITH i AS (#{body}) SELECT user_id FROM i) SELECT user_id FROM a"
    expect_rewrite(
      "SELECT users.id FROM public.users WHERE users.id IN (#{inner}) AND users.id IN (#{inner})",
      "WITH a AS (WITH i AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $1) " \
      "SELECT user_id FROM i) SELECT users.id FROM public.users WHERE users.id IN (SELECT user_id FROM a) " \
      "AND users.id IN (SELECT user_id FROM a)"
    )
  end

  it "doesn't merge bodies whose literals differ in value or shape", :aggregate_failures do
    [
      [body(1), body(2)],
      [body(1), body("'1'")],
      [body(1), body("1::bigint")],
      [body(1), "SELECT user_id FROM public.user_account_associations WHERE account_id = 1 AND true"]
    ].each do |one, other|
      sql = "SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (#{one}) SELECT user_id FROM a) " \
            "AND users.id IN (WITH a AS (#{other}) SELECT user_id FROM a)"

      expect(rewritten(sql)).to eq([]), other
    end
  end

  it "doesn't merge copies whose materialization or column names differ", :aggregate_failures do
    [
      ["a AS MATERIALIZED", "a AS"],
      ["a AS NOT MATERIALIZED", "a AS"],
      ["a AS MATERIALIZED", "a AS NOT MATERIALIZED"],
      ["a (user_id) AS", "a (uid) AS"]
    ].each do |one, other|
      sql = "SELECT users.id FROM public.users WHERE users.id IN (WITH #{one} (#{body}) SELECT * FROM a) " \
            "AND users.id IN (WITH #{other} (#{body}) SELECT * FROM a)"

      expect(rewritten(sql)).to eq([]), other
    end
  end

  it "fires only when at least two copies merge" do
    sql = "WITH b AS (#{body(2)}) SELECT users.id FROM public.users " \
          "WHERE users.id IN (WITH a AS (#{body}) SELECT user_id FROM a) AND users.id IN (SELECT user_id FROM b)"

    expect(rewritten(sql)).to eq([])
  end

  it "refuses a correlated CTE", :aggregate_failures do
    [
      "SELECT user_account_associations.user_id FROM public.user_account_associations " \
      "WHERE user_account_associations.user_id = users.id",
      "SELECT user_id FROM public.user_account_associations WHERE name IS NOT NULL",
      "SELECT user_id FROM public.user_account_associations WHERE EXISTS (SELECT 1 FROM public.users u2 " \
      "WHERE u2.id = users.id)",
      "SELECT uaa.user_id FROM public.user_account_associations uaa WHERE EXISTS (SELECT 1 FROM public.users) " \
      "AND uaa.user_id IN (SELECT users.id FROM public.users x WHERE x.id = users.id)"
    ].each do |correlated|
      sql = "SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (#{correlated}) SELECT user_id FROM a) " \
            "AND users.id IN (WITH a AS (#{correlated}) SELECT user_id FROM a)"

      expect(conn.exec(sql).ntuples).to be_positive, correlated
      expect(rewritten(sql)).to eq([]), correlated
    end
  end

  it "refuses a CTE that reads another CTE from outside its body, even when a table has that name" do
    conn.exec("CREATE TABLE public.b (user_id int)")
    sql = "WITH b AS (#{body}) SELECT users.id FROM public.users " \
          "WHERE users.id IN (WITH a AS (SELECT user_id FROM b) SELECT user_id FROM a) " \
          "AND users.id IN (WITH a AS (SELECT user_id FROM b) SELECT user_id FROM a)"

    expect(rewritten(sql)).to eq([])
  end

  it "hoists sibling copies but not a CTE that reads its earlier sibling, even when a table has that name" do
    conn.exec("CREATE TABLE public.b (user_id int)")
    cte = "WITH b AS (#{body}), a AS (SELECT user_id FROM b) SELECT user_id FROM a"
    expect_rewrite(
      "SELECT users.id FROM public.users WHERE users.id IN (#{cte}) AND users.id IN (#{cte})",
      "WITH b AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $1) " \
      "SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (SELECT user_id FROM b) SELECT user_id FROM a) " \
      "AND users.id IN (WITH a AS (SELECT user_id FROM b) SELECT user_id FROM a)"
    )
  end

  it "refuses a copy that reads a later sibling of a RECURSIVE WITH, even when a table has that name" do
    copy = "WITH a AS (SELECT users.id FROM users WHERE users.name = 'a') SELECT a.id FROM a"
    sql = "SELECT p.id FROM public.users p WHERE p.id IN (WITH RECURSIVE r AS (SELECT a.id FROM (#{copy}) a), " \
          "users AS (SELECT user_id AS id, 'a' AS name FROM public.user_account_associations) SELECT r.id FROM r) " \
          "AND p.id IN (#{copy})"

    expect(conn.exec(sql).ntuples).to be_positive
    expect(rewritten(sql)).to eq([])
  end

  it "hoists a copy that reads a table named like a later sibling CTE" do
    copy = "SELECT users.id FROM users WHERE users.name = 'a'"
    expect_rewrite(
      "SELECT p.id FROM public.users p WHERE p.id IN (WITH a AS (#{copy}), " \
      "users AS (SELECT user_id AS id FROM public.user_account_associations WHERE account_id = 1) " \
      "SELECT a.id FROM a JOIN users ON users.id = a.id) AND p.id IN (WITH a AS (#{copy}) SELECT a.id FROM a)",
      "WITH a AS (SELECT users.id FROM users WHERE users.name = $1) SELECT p.id FROM public.users p " \
      "WHERE p.id IN (WITH users AS (SELECT user_id AS id FROM public.user_account_associations " \
      "WHERE account_id = $2) SELECT a.id FROM a JOIN users ON users.id = a.id) AND p.id IN (SELECT a.id FROM a)"
    )
  end

  it "keeps the copies' name when only a schema-qualified table has it" do
    expect_rewrite(
      "SELECT p.id FROM public.users p WHERE p.id IN (WITH users AS (#{body}) SELECT user_id FROM users) " \
      "AND p.id IN (WITH users AS (#{body}) SELECT user_id FROM users)",
      "WITH users AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $1) " \
      "SELECT p.id FROM public.users p WHERE p.id IN (SELECT user_id FROM users) " \
      "AND p.id IN (SELECT user_id FROM users)"
    )
  end

  it "refuses a CTE that calls a volatile function" do
    volatile = "SELECT user_id FROM public.user_account_associations WHERE account_id < random() * 3"
    sql = "SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (#{volatile}) SELECT user_id FROM a) " \
          "AND users.id IN (WITH a AS (#{volatile}) SELECT user_id FROM a)"

    expect(rewritten(sql)).to eq([])
  end

  it "refuses recursive CTEs, and a query with a recursive top-level WITH", :aggregate_failures do
    recursive = "WITH RECURSIVE a AS (#{body}) SELECT user_id FROM a"
    [
      "SELECT users.id FROM public.users WHERE users.id IN (#{recursive}) AND users.id IN (#{recursive})",
      "WITH RECURSIVE r AS (SELECT 1 AS n) SELECT users.id FROM public.users " \
      "WHERE users.id IN (WITH a AS (#{body}) SELECT user_id FROM a) " \
      "AND users.id IN (WITH a AS (#{body}) SELECT user_id FROM a)"
    ].each do |sql|
      expect(rewritten(sql)).to eq([]), sql
    end
  end

  it "refuses a query with a data-modifying CTE" do
    _, literals = literals_for(
      "SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (#{body}) SELECT user_id FROM a) " \
      "AND users.id IN (WITH a AS (#{body}) SELECT user_id FROM a) AND users.id <> 0"
    )
    select = "SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (#{body("$1")}) SELECT user_id FROM a) " \
             "AND users.id IN (WITH a AS (#{body("$2")}) SELECT user_id FROM a)"
    writes = "WITH d AS (DELETE FROM public.users WHERE users.id = $3 RETURNING users.id) #{select} " \
             "AND users.id NOT IN (SELECT d.id FROM d)"

    expect(rule.rewrites(PgQuery.parse(select), catalog, literals).size).to eq(1)
    expect(rule.rewrites(PgQuery.parse(writes), catalog, literals)).to eq([])
  end

  it "makes no rewrite without the literals oracle" do
    redacted, = literals_for(
      "SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (#{body}) SELECT user_id FROM a) " \
      "AND users.id IN (WITH a AS (#{body}) SELECT user_id FROM a)"
    )

    expect(rule.rewrites(PgQuery.parse(redacted), catalog, nil)).to eq([])
  end

  it "doesn't change the parse it was given" do
    redacted, literals = literals_for(
      "SELECT users.id FROM public.users WHERE users.id IN (WITH a AS (#{body}) SELECT user_id FROM a) " \
      "AND users.id IN (WITH a AS (#{body}) SELECT user_id FROM a)"
    )
    parse = PgQuery.parse(redacted)
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

    expect(rule.rewrites(parse, catalog, literals).size).to eq(1)
    expect(parse.tree).to eq(before)
  end
end
