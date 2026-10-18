# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/subquery_distinct_removal"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' subquery_distinct_removal, on a real server: a
# subquery whose reader ignores duplicates and order, the subquery of an IN,
# = ANY, NOT IN, or <> ALL, or an arm under a UNION, INTERSECT, or EXCEPT
# without ALL, loses its DISTINCT, its ORDER BY, and a GROUP BY of just its
# select list's columns, and every rewrite returns the original's rows.
RSpec.describe Quaack::Enclave::RewriteRules::SubqueryDistinctRemoval do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # Duplicate user_ids in enrollments and submissions, a NULL user_id, and
  # names that differ only in case, so a rewrite that changed which values
  # a reader sees, or how many, would show.
  before do
    conn.exec(<<~SQL)
      CREATE EXTENSION citext SCHEMA public;
      CREATE COLLATION public.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
      CREATE TABLE public.users (id int PRIMARY KEY, name text, workflow_state text);
      CREATE TABLE public.enrollments (id int PRIMARY KEY, user_id int, course_id int, type text, created_at int);
      CREATE TABLE public.submissions (id int PRIMARY KEY, user_id int, assignment_id int, score numeric);
      CREATE TABLE public.tags (id int PRIMARY KEY, name public.citext, label text COLLATE public.ci, plain text,
                                data jsonb);
      CREATE TABLE public.ids (id int);
      INSERT INTO public.users VALUES
        (1, 'ann', 'active'), (2, 'bob', 'active'), (3, 'cy', 'deleted'), (4, 'ANN', 'active'), (5, NULL, 'active'),
        (6, 'student', 'active');
      INSERT INTO public.enrollments VALUES
        (1, 1, 1, 'student', 10), (2, 1, 2, 'student', 20), (3, 2, 1, 'teacher', 30), (4, 2, 1, 'student', 40),
        (5, 3, 2, 'student', 50), (6, NULL, 3, 'student', 60), (7, 1, 1, 'ta', 70);
      INSERT INTO public.submissions VALUES
        (1, 1, 1, 10), (2, 1, 2, 9.5), (3, 2, 1, 10.0), (4, 4, 1, NULL), (5, 2, 2, 7);
      INSERT INTO public.tags VALUES
        (1, 'ann', 'ann', 'ann', '{}'), (2, 'ANN', 'ANN', 'ANN', '{}'), (3, 'bob', 'bob', 'bob', '[]');
      INSERT INTO public.ids VALUES (1), (1), (2);
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  def generated(sql) = rule.rewrites(PgQuery.parse(redacted(sql).sql), catalog)

  def rewritten(sql) = generated(sql).map { Quaack::Enclave::Deparse.faithfully(it.tree) }

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

  # sql's rows are rewrite's, and aren't empty.
  def expect_same_rows(sql, rewrite)
    original = redacted(sql)
    want = rows(original.sql, original.placeholder_map)
    expect(want).not_to be_empty
    expect(rows(rewrite, original.placeholder_map)).to eq(want)
  end

  # The rewrites of sql are exactly expected, in order, and each returns
  # sql's rows.
  def expect_rewrites(sql, *expected)
    expect(rewritten(sql)).to eq(expected)
    expected.each { expect_same_rows(sql, it) }
  end

  # For each [refused, fires] pair, the rule leaves refused alone and
  # rewrites fires, its positive twin. Both run on the server.
  def expect_refusals(pairs)
    pairs.each do |refused, fires|
      expect(conn.exec(refused).ntuples).to be_positive, refused
      expect(rewritten(refused)).to eq([]), refused
      expect(rewritten(fires).size).to eq(1), fires
    end
  end

  def users_where(condition) = "SELECT users.id FROM public.users WHERE #{condition}"

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["subquery_distinct_removal",
       "The subquery of an IN, = ANY, NOT IN, or <> ALL, or an arm under a UNION, INTERSECT, or EXCEPT without " \
       "ALL, loses its DISTINCT, its ORDER BY, and a GROUP BY of just its select list's columns, since its " \
       "reader ignores duplicates and order."]
    )
  end

  it "drops the DISTINCT of a Rails IN subquery, and states no assumption" do
    sql = "SELECT users.* FROM public.users WHERE users.id IN " \
          "(SELECT DISTINCT enrollments.user_id FROM public.enrollments WHERE enrollments.course_id = 1)"

    expect_rewrites(sql, "SELECT users.* FROM public.users WHERE users.id IN " \
                         "(SELECT enrollments.user_id FROM public.enrollments WHERE enrollments.course_id = $1)")
    expect(generated(sql).map(&:assumptions)).to eq([[]])
  end

  it "drops the DISTINCT under NOT IN, = ANY, OPERATOR(pg_catalog.=) ANY, and <> ALL" do
    subquery = "SELECT DISTINCT e.user_id FROM public.enrollments e WHERE e.course_id = 2"
    kept = "SELECT e.user_id FROM public.enrollments e WHERE e.course_id = $1"
    { "users.id NOT IN" => "NOT users.id IN", "users.id = ANY" => "users.id = ANY",
      "users.id OPERATOR(pg_catalog.=) ANY" => "users.id OPERATOR(pg_catalog.=) ANY",
      "users.id != ALL" => "users.id <> ALL" }.each do |test, deparsed|
      expect_rewrites(users_where("#{test} (#{subquery})"), users_where("#{deparsed} (#{kept})"))
    end
  end

  it "drops the DISTINCT of a NOT IN in the select list, whose NULLs it keeps" do
    expect_rewrites(
      "SELECT users.id, users.id NOT IN (SELECT DISTINCT e.user_id FROM public.enrollments e) AS absent " \
      "FROM public.users",
      "SELECT users.id, NOT users.id IN (SELECT e.user_id FROM public.enrollments e) AS absent FROM public.users"
    )
    expect(rows("SELECT users.id NOT IN (SELECT e.user_id FROM public.enrollments e) FROM public.users", {}))
      .to include([nil], ["f"])
  end

  it "drops a GROUP BY of exactly the select list's columns, in any order, and of a bare column" do
    expect_rewrites(
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e WHERE e.type = 'student' " \
                  "GROUP BY e.user_id)"),
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e WHERE e.type = $1)")
    )
    expect_rewrites(
      users_where("users.id IN (SELECT user_id FROM public.enrollments GROUP BY user_id)"),
      users_where("users.id IN (SELECT user_id FROM public.enrollments)")
    )
    expect_rewrites(
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e GROUP BY DISTINCT e.user_id)"),
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e)")
    )
    expect_rewrites(
      "SELECT DISTINCT e.user_id, e.course_id FROM public.enrollments e UNION " \
      "SELECT s.user_id, s.assignment_id FROM public.submissions s GROUP BY s.assignment_id, s.user_id",
      "SELECT e.user_id, e.course_id FROM public.enrollments e UNION " \
      "SELECT s.user_id, s.assignment_id FROM public.submissions s GROUP BY s.assignment_id, s.user_id",
      "SELECT DISTINCT e.user_id, e.course_id FROM public.enrollments e UNION " \
      "SELECT s.user_id, s.assignment_id FROM public.submissions s"
    )
  end

  it "drops the ORDER BY of a Rails IN subquery with no LIMIT" do
    expect_rewrites(
      users_where("users.id IN (SELECT enrollments.user_id FROM public.enrollments " \
                  "WHERE enrollments.type = 'student' ORDER BY enrollments.created_at DESC)"),
      users_where("users.id IN (SELECT enrollments.user_id FROM public.enrollments WHERE enrollments.type = $1)")
    )
  end

  it "drops DISTINCT, GROUP BY, and ORDER BY together, in one rewrite" do
    expect_rewrites(
      users_where("users.id IN (SELECT DISTINCT e.user_id FROM public.enrollments e GROUP BY e.user_id " \
                  "ORDER BY e.user_id)"),
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e)")
    )
  end

  it "drops only the ORDER BY when the DISTINCT or GROUP BY must stay" do
    expect_rewrites(
      "SELECT users.id FROM public.users WHERE users.name IN " \
      "(SELECT DISTINCT lower(e.type) FROM public.enrollments e ORDER BY 1)",
      "SELECT users.id FROM public.users WHERE users.name IN (SELECT DISTINCT lower(e.type) FROM public.enrollments e)"
    )
    expect_rewrites(
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e GROUP BY e.user_id, e.course_id " \
                  "ORDER BY e.course_id)"),
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e GROUP BY e.user_id, e.course_id)")
    )
    expect_rewrites(
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e GROUP BY e.user_id " \
                  "HAVING count(*) > 1 ORDER BY e.user_id)"),
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e GROUP BY e.user_id HAVING count(*) > $1)")
    )
  end

  it "drops the DISTINCT of a correlated subquery whose selected column is its own" do
    expect_rewrites(
      "SELECT users.id FROM public.users WHERE 1 IN " \
      "(SELECT DISTINCT e.course_id FROM public.enrollments e WHERE e.user_id = users.id)",
      "SELECT users.id FROM public.users WHERE $1 IN " \
      "(SELECT e.course_id FROM public.enrollments e WHERE e.user_id = users.id)"
    )
  end

  it "drops the DISTINCT of an arm under UNION, and keeps the UNION's own ORDER BY" do
    expect_rewrites(
      "SELECT DISTINCT e.user_id FROM public.enrollments e WHERE e.course_id = 1 " \
      "UNION SELECT s.user_id FROM public.submissions s ORDER BY 1",
      "SELECT e.user_id FROM public.enrollments e WHERE e.course_id = $1 " \
      "UNION SELECT s.user_id FROM public.submissions s ORDER BY 1"
    )
  end

  it "drops the DISTINCT of an arm under UNION ALL when a UNION is above it" do
    expect_rewrites(
      "SELECT s.user_id FROM public.submissions s UNION (SELECT DISTINCT e.user_id FROM public.enrollments e " \
      "UNION ALL SELECT s.assignment_id FROM public.submissions s)",
      "SELECT s.user_id FROM public.submissions s UNION (SELECT e.user_id FROM public.enrollments e " \
      "UNION ALL SELECT s.assignment_id FROM public.submissions s)"
    )
  end

  it "rewrites each arm of an IN's UNION ALL, and each side of an EXCEPT, once each" do
    expect_rewrites(
      users_where("users.id IN (SELECT DISTINCT e.user_id FROM public.enrollments e " \
                  "UNION ALL SELECT DISTINCT s.user_id FROM public.submissions s)"),
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e " \
                  "UNION ALL SELECT DISTINCT s.user_id FROM public.submissions s)"),
      users_where("users.id IN (SELECT DISTINCT e.user_id FROM public.enrollments e " \
                  "UNION ALL SELECT s.user_id FROM public.submissions s)")
    )
    expect_rewrites(
      users_where("users.id IN ((SELECT e.user_id FROM public.enrollments e ORDER BY e.created_at) " \
                  "EXCEPT SELECT DISTINCT s.user_id FROM public.submissions s)"),
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e " \
                  "EXCEPT SELECT DISTINCT s.user_id FROM public.submissions s)"),
      users_where("users.id IN ((SELECT e.user_id FROM public.enrollments e ORDER BY e.created_at) " \
                  "EXCEPT SELECT s.user_id FROM public.submissions s)")
    )
  end

  it "drops the ORDER BY of an IN's set operation, and of one under a UNION" do
    expect_rewrites(
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e " \
                  "UNION SELECT s.user_id FROM public.submissions s ORDER BY 1)"),
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e " \
                  "UNION SELECT s.user_id FROM public.submissions s)")
    )
    expect_rewrites(
      "SELECT s.user_id FROM public.submissions s UNION (SELECT e.user_id FROM public.enrollments e " \
      "UNION ALL SELECT s.assignment_id FROM public.submissions s ORDER BY 1)",
      "SELECT s.user_id FROM public.submissions s UNION (SELECT e.user_id FROM public.enrollments e " \
      "UNION ALL SELECT s.assignment_id FROM public.submissions s)"
    )
  end

  it "drops the DISTINCT of an arm of an IN's INTERSECT ALL" do
    expect_rewrites(
      users_where("users.id IN (SELECT DISTINCT e.user_id FROM public.enrollments e " \
                  "INTERSECT ALL SELECT s.user_id FROM public.submissions s)"),
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e " \
                  "INTERSECT ALL SELECT s.user_id FROM public.submissions s)")
    )
  end

  it "rewrites two IN subqueries one at a time, each from the original" do
    expect_rewrites(
      users_where("users.id IN (SELECT DISTINCT e.user_id FROM public.enrollments e) " \
                  "AND users.id IN (SELECT DISTINCT s.user_id FROM public.submissions s)"),
      users_where("users.id IN (SELECT e.user_id FROM public.enrollments e) " \
                  "AND users.id IN (SELECT DISTINCT s.user_id FROM public.submissions s)"),
      users_where("users.id IN (SELECT DISTINCT e.user_id FROM public.enrollments e) " \
                  "AND users.id IN (SELECT s.user_id FROM public.submissions s)")
    )
  end

  it "leaves alone a subquery whose reader can see duplicates or order" do
    distinct = "SELECT DISTINCT e.user_id FROM public.enrollments e"
    expect_refusals(
      [[users_where("EXISTS (#{distinct} WHERE e.user_id = users.id)"), users_where("users.id IN (#{distinct})")],
       ["SELECT (#{distinct} WHERE e.id = 1)", users_where("users.id IN (#{distinct})")],
       [users_where("users.id = ANY (ARRAY(#{distinct}))"), users_where("users.id = ANY (#{distinct})")],
       ["SELECT s.user_id FROM (#{distinct}) s", users_where("users.id IN (#{distinct})")],
       [distinct, users_where("users.id IN (#{distinct})")],
       [users_where("users.id < ANY (#{distinct})"), users_where("users.id = ANY (#{distinct})")],
       [users_where("users.id <> ANY (#{distinct})"), users_where("users.id = ANY (#{distinct})")],
       [users_where("users.id = ALL (#{distinct} WHERE e.user_id = 1)"),
        users_where("users.id <> ALL (#{distinct} WHERE e.user_id = 1)")],
       ["#{distinct} UNION ALL SELECT s.user_id FROM public.submissions s",
        "#{distinct} UNION SELECT s.user_id FROM public.submissions s"],
       [users_where("users.id IN (SELECT s.user_id FROM public.submissions s UNION ALL #{distinct} LIMIT 3)"),
        users_where("users.id IN (SELECT s.user_id FROM public.submissions s UNION ALL #{distinct})")]]
    )
  end

  # A UNION ALL or INTERSECT ALL gives the same set for any count of each
  # row, but EXCEPT ALL subtracts counts, so an arm under it needs its
  # DISTINCT even under an IN, or a UNION above.
  it "leaves alone an arm with an EXCEPT ALL between it and its reader, where the counts change the rows" do
    sql = users_where("users.id IN (SELECT e.user_id FROM public.enrollments e " \
                      "EXCEPT ALL SELECT DISTINCT s.user_id FROM public.submissions s)")
    expect_refusals(
      [[sql, sql.sub("EXCEPT ALL", "EXCEPT")],
       ["SELECT 1 UNION (SELECT e.user_id FROM public.enrollments e " \
        "EXCEPT ALL SELECT DISTINCT s.user_id FROM public.submissions s)",
        "SELECT 1 UNION (SELECT e.user_id FROM public.enrollments e " \
        "UNION ALL SELECT DISTINCT s.user_id FROM public.submissions s)"]]
    )
    original = redacted(sql)
    expect(rows(original.sql.sub("SELECT DISTINCT", "SELECT"), original.placeholder_map))
      .not_to eq(rows(original.sql, original.placeholder_map))
  end

  it "leaves alone a subquery with DISTINCT ON, LIMIT, OFFSET, or FETCH" do
    plain = users_where("users.id IN (SELECT DISTINCT e.user_id FROM public.enrollments e ORDER BY e.user_id)")
    expect_refusals(
      [[users_where("users.id IN (SELECT DISTINCT ON (e.course_id) e.user_id FROM public.enrollments e " \
                    "ORDER BY e.course_id, e.created_at)"), plain],
       [plain.sub(")", " LIMIT 2)"), plain],
       [plain.sub(")", " OFFSET 1)"), plain],
       [plain.sub(")", " FETCH FIRST 2 ROWS ONLY)"), plain]]
    )
  end

  # SupportedSql refuses a locking clause, so intake never hands the rule
  # one, and the query goes to the rule unredacted.
  it "leaves alone a subquery with a locking clause" do
    locked = users_where("users.id IN (SELECT e.user_id FROM public.enrollments e ORDER BY e.user_id FOR UPDATE)")
    expect(conn.exec(locked).ntuples).to be_positive
    expect(rule.rewrites(PgQuery.parse(locked), catalog)).to eq([])
    expect(rule.rewrites(PgQuery.parse(locked.sub(" FOR UPDATE", "")), catalog).size).to eq(1)
  end

  # Likewise, SupportedSql refuses any statement but a SELECT.
  it "leaves alone a statement that isn't a SELECT" do
    select = users_where("users.id IN (SELECT DISTINCT e.user_id FROM public.enrollments e)")
    expect(rule.rewrites(PgQuery.parse("CREATE VIEW public.v AS #{select}"), catalog)).to eq([])
    expect(rule.rewrites(PgQuery.parse(select), catalog).size).to eq(1)
  end

  it "leaves alone a subquery whose select list calls a set-returning, aggregate, or volatile function" do
    ordered = users_where("users.id IN (SELECT e.user_id FROM public.enrollments e ORDER BY e.id)")
    expect_refusals(
      [[users_where("users.id IN (SELECT unnest(ARRAY[e.user_id, e.course_id]) FROM public.enrollments e " \
                    "ORDER BY e.id)"), ordered],
       [users_where("users.id IN (SELECT max(e.user_id) FROM public.enrollments e GROUP BY e.course_id " \
                    "ORDER BY 1)"), ordered],
       [users_where("users.id IN (SELECT e.user_id + floor(random())::int FROM public.enrollments e " \
                    "ORDER BY e.id)"), ordered]]
    )
  end

  # DISTINCT and GROUP BY merge values their type's equality calls equal.
  # A reader that compares them another way, as text = citext compares as
  # text, or COLLATE "C" compares a case-insensitive column, would tell the
  # merged values apart. So the rule keeps them unless each selected column
  # is a column of a table in the subquery's own FROM, of a type whose
  # equality the catalog knows, with a deterministic collation.
  it "keeps a DISTINCT or GROUP BY of anything but plain columns of comparable types in its own FROM" do
    plain = users_where("users.name IN (SELECT DISTINCT t.plain FROM public.tags t)")
    own = users_where("users.id IN (SELECT DISTINCT e.user_id FROM public.enrollments e)")
    expect_refusals(
      [[users_where("users.name IN (SELECT DISTINCT t.name FROM public.tags t)"), plain],
       [users_where("users.name COLLATE \"C\" IN (SELECT DISTINCT t.label FROM public.tags t)"), plain],
       [users_where("users.name COLLATE \"C\" IN (SELECT t.label FROM public.tags t GROUP BY t.label)"),
        users_where("users.name IN (SELECT t.plain FROM public.tags t GROUP BY t.plain)")],
       [users_where("'{}'::jsonb IN (SELECT DISTINCT t.data FROM public.tags t)"), plain],
       [users_where("users.name IN (SELECT DISTINCT t.plain COLLATE \"C\" FROM public.tags t)"), plain],
       [users_where("users.id IN (SELECT DISTINCT users.id FROM public.enrollments e WHERE e.user_id = users.id)"),
        users_where("users.id IN (SELECT DISTINCT e.user_id FROM public.enrollments e WHERE e.user_id = users.id)")],
       [users_where("users.name IN (SELECT DISTINCT name FROM public.enrollments)"),
        users_where("users.name IN (SELECT DISTINCT type FROM public.enrollments)")],
       [users_where("users.id IN (SELECT DISTINCT user_id FROM public.enrollments, (SELECT 1 AS one) x)"),
        users_where("users.id IN (SELECT DISTINCT user_id FROM public.enrollments)")],
       [users_where("users.id IN (SELECT DISTINCT user_id FROM public.enrollments JOIN public.submissions " \
                    "USING (user_id))"),
        users_where("users.id IN (SELECT DISTINCT user_id FROM public.enrollments)")],
       [users_where("users.id IN (SELECT DISTINCT ids.* FROM public.ids)"),
        users_where("users.id IN (SELECT DISTINCT ids.id FROM public.ids)")],
       [users_where("users.id IN (SELECT DISTINCT s.user_id FROM (SELECT e.user_id FROM public.enrollments e) s)"),
        own],
       [users_where("users.name IN (SELECT DISTINCT t.plain FROM public.tags t(id, plain, label, other))"), plain]]
    )
  end

  it "keeps a GROUP BY of ordinals, expressions, or other columns than the select list's" do
    plain = users_where("users.id IN (SELECT e.user_id FROM public.enrollments e GROUP BY e.user_id)")
    expect_refusals(
      [[users_where("users.id IN (SELECT e.user_id FROM public.enrollments e GROUP BY 1)"), plain],
       [users_where("users.id IN (SELECT e.user_id FROM public.enrollments e GROUP BY e.user_id + 0, e.user_id)"),
        plain],
       [users_where("users.id IN (SELECT e.user_id FROM public.enrollments e GROUP BY e.user_id, e.course_id)"),
        plain],
       [users_where("users.id IN (SELECT e.user_id FROM public.enrollments e GROUP BY user_id)"), plain],
       ["SELECT e.id, e.user_id FROM public.enrollments e GROUP BY e.id UNION " \
        "SELECT s.id, s.user_id FROM public.submissions s",
        "SELECT e.id, e.user_id FROM public.enrollments e GROUP BY e.user_id, e.id UNION " \
        "SELECT s.id, s.user_id FROM public.submissions s"]]
    )
  end
end
