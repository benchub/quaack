# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/count_distinct_to_subquery"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' count_distinct_to_subquery, on a real server: a
# count(DISTINCT e), alone or with its GROUP BY columns, becomes a count of
# a SELECT DISTINCT's rows, and every rewrite returns the original's rows.
RSpec.describe Quaack::Enclave::RewriteRules::CountDistinctToSubquery do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # Repeated user_ids in a course, NULL user_ids, a course whose user_ids
  # are all NULL, and names that differ only in case under a
  # case-insensitive collation, so a rewrite that counted copies, NULLs, or
  # lost a group would show.
  before do
    conn.exec(<<~SQL)
      CREATE COLLATION public.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
      CREATE TABLE public.courses (id int PRIMARY KEY, account_id int, name text);
      CREATE TABLE public.events (id int PRIMARY KEY, course_id int, user_id int, kind text, label text COLLATE public.ci,
                                  created_at int);
      INSERT INTO public.courses VALUES (1, 10, 'math'), (2, 10, 'art'), (3, 20, 'law'), (4, 20, 'gym');
      INSERT INTO public.events VALUES
        (1, 1, 1, 'view', 'ann', 1), (2, 1, 1, 'view', 'ANN', 2), (3, 1, 2, 'post', 'bob', 3),
        (4, 1, NULL, 'view', NULL, 4), (5, 2, 3, 'view', 'cy', 5), (6, 2, 3, 'post', 'Cy', 6),
        (7, 3, NULL, 'view', NULL, 7), (8, 3, NULL, 'post', NULL, 8), (9, NULL, 4, 'view', 'dee', 9),
        (10, NULL, 4, 'view', 'dee', 10);
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  def generated(sql) = rule.rewrites(PgQuery.parse(redacted(sql).sql), catalog)

  def rewritten(sql) = generated(sql).map { Quaack::Enclave::Deparse.faithfully(it.tree) }

  def rows(sql, map, ordered: false)
    name = "quaack_rule_spec"
    binding = Quaack::Enclave::Redaction.binding(sql, map)
    binding.prepare(conn, name)
    result = binding.execute(conn, name)
    [result.fields, ordered ? result.values : result.values.sort_by(&:to_s)]
  ensure
    begin
      conn.exec("DEALLOCATE #{name}")
    rescue StandardError
      nil
    end
  end

  # sql's rows and column names are rewrite's.
  def expect_same_rows(sql, rewrite, ordered: false)
    original = redacted(sql)
    want = rows(original.sql, original.placeholder_map, ordered:)
    expect(want.last).not_to be_empty
    expect(rows(rewrite, original.placeholder_map, ordered:)).to eq(want)
  end

  def expect_rewrite(sql, expected, ordered: false)
    expect(rewritten(sql)).to eq([expected])
    expect_same_rows(sql, expected, ordered:)
  end

  # For each [refused, fires] pair, the rule leaves refused alone and
  # rewrites fires, its positive twin. Both run on the server.
  def expect_refusals(pairs)
    pairs.each do |refused, fires|
      conn.exec(refused)
      expect(rewritten(refused)).to eq([]), refused
      expect(rewritten(fires).size).to eq(1), fires
    end
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["count_distinct_to_subquery",
       "A count(DISTINCT e), alone or with its GROUP BY columns, counts the rows of a SELECT DISTINCT of those " \
       "columns and e, which Postgres can hash instead of sorting inside the aggregate."]
    )
  end

  it "counts a grouped count(DISTINCT) from a SELECT DISTINCT, keeps the output names, and states no assumption" do
    sql = "SELECT events.course_id, count(DISTINCT events.user_id) AS users FROM public.events " \
          "WHERE events.created_at > 0 GROUP BY events.course_id"

    expect_rewrite(sql, "SELECT d_1.course_id, count(d_1.user_id_1) AS users FROM " \
                        "(SELECT DISTINCT events.course_id, events.user_id AS user_id_1 FROM public.events " \
                        "WHERE events.created_at > $1) d_1 GROUP BY d_1.course_id")
    expect(generated(sql).map(&:assumptions)).to eq([[]])
    expect(rows(redacted(sql).sql, redacted(sql).placeholder_map).last).to include(["3", "0"], [nil, "1"])
  end

  it "counts an ungrouped count(DISTINCT), which still gives 0 on no rows" do
    sql = "SELECT count(DISTINCT events.user_id) FROM public.events WHERE events.kind = 'view'"
    expect_rewrite(sql, "SELECT count(d_1.user_id_1) FROM (SELECT DISTINCT events.user_id AS user_id_1 " \
                        "FROM public.events WHERE events.kind = $1) d_1")

    empty = "SELECT count(DISTINCT events.user_id) FROM public.events WHERE events.kind = 'none'"
    expect(rows(rewritten(empty).first, redacted(empty).placeholder_map)).to eq([["count"], [["0"]]])
  end

  it "takes a join, two grouping columns in any order, an expression, pg_catalog.count, and a case-insensitive " \
     "collation" do
    expect_rewrite(
      "SELECT c.account_id, count(DISTINCT lower(e.kind)), c.name FROM public.events e " \
      "JOIN public.courses c ON c.id = e.course_id GROUP BY c.name, c.account_id",
      "SELECT d_1.account_id, count(d_1.value_1), d_1.name FROM (SELECT DISTINCT c.account_id, c.name, " \
      "lower(e.kind) AS value_1 FROM public.events e JOIN public.courses c ON c.id = e.course_id) d_1 " \
      "GROUP BY d_1.name, d_1.account_id"
    )
    expect_rewrite(
      "SELECT e.course_id, pg_catalog.count(DISTINCT e.label) AS n FROM public.events e GROUP BY e.course_id",
      "SELECT d_1.course_id, pg_catalog.count(d_1.label_1) AS n FROM (SELECT DISTINCT e.course_id, e.label AS " \
      "label_1 FROM public.events e) d_1 GROUP BY d_1.course_id"
    )
  end

  it "rewrites ORDER BY a grouping column, an output name, and an ordinal, and keeps LIMIT, OFFSET, and WITH" do
    expect_rewrite(
      "SELECT e.course_id, count(DISTINCT e.user_id) AS users FROM public.events e GROUP BY e.course_id " \
      "ORDER BY users DESC, e.course_id NULLS FIRST, 1 LIMIT 3 OFFSET 1",
      "SELECT d_1.course_id, count(d_1.user_id_1) AS users FROM (SELECT DISTINCT e.course_id, e.user_id AS " \
      "user_id_1 FROM public.events e) d_1 GROUP BY d_1.course_id ORDER BY users DESC, d_1.course_id NULLS FIRST, " \
      "1 LIMIT $1 OFFSET $2", ordered: true
    )
    expect_rewrite(
      "WITH recent AS (SELECT * FROM public.events WHERE created_at > 2) " \
      "SELECT recent.kind, count(DISTINCT recent.user_id) FROM recent GROUP BY recent.kind ORDER BY count, recent.kind",
      "WITH recent AS (SELECT * FROM public.events WHERE created_at > $1) SELECT d_1.kind, " \
      "count(d_1.user_id_1) FROM (SELECT DISTINCT recent.kind, recent.user_id AS user_id_1 FROM recent) d_1 " \
      "GROUP BY d_1.kind ORDER BY count, d_1.kind", ordered: true
    )
  end

  it "refuses what it can't rewrite, and rewrites each one's twin" do
    base = "SELECT e.course_id, count(DISTINCT e.user_id) AS n FROM public.events e"
    fires = "#{base} GROUP BY e.course_id"
    expect_refusals(
      [["#{fires} HAVING count(DISTINCT e.user_id) > 0", fires],
       ["#{base} GROUP BY e.course_id, e.kind", fires],
       ["#{base} GROUP BY 1", fires],
       ["SELECT DISTINCT e.course_id, count(DISTINCT e.user_id) AS n FROM public.events e GROUP BY e.course_id",
        fires],
       ["#{fires} ORDER BY count(DISTINCT e.user_id)", "#{fires} ORDER BY n"],
       ["#{fires} ORDER BY e.course_id + 1", "#{fires} ORDER BY e.course_id"],
       ["SELECT e.course_id, count(DISTINCT e.user_id) FILTER (WHERE e.kind = 'view') FROM public.events e " \
        "GROUP BY e.course_id", fires],
       ["SELECT e.course_id, count(DISTINCT e.user_id ORDER BY e.user_id) FROM public.events e GROUP BY e.course_id",
        fires],
       ["SELECT e.course_id, count(e.user_id) FROM public.events e GROUP BY e.course_id", fires],
       ["SELECT c.id, count(DISTINCT e.user_id) FROM public.events e JOIN public.courses c ON c.id = e.course_id " \
        "GROUP BY c.id ORDER BY c.name", "SELECT c.id, count(DISTINCT e.user_id) FROM public.events e " \
                                         "JOIN public.courses c ON c.id = e.course_id GROUP BY c.id ORDER BY c.id"],
       ["SELECT e.course_id, count(DISTINCT e.user_id) AS a, count(DISTINCT e.kind) AS b FROM public.events e " \
        "GROUP BY e.course_id", fires],
       ["SELECT e.course_id, count(DISTINCT e.user_id), max(e.id) FROM public.events e GROUP BY e.course_id", fires],
       ["SELECT e.course_id, count(DISTINCT e.user_id), rank() OVER () FROM public.events e GROUP BY e.course_id", fires],
       ["SELECT course_id, count(DISTINCT e.user_id) AS n FROM public.events e GROUP BY course_id", fires],
       ["SELECT e.id AS eid, c.id AS cid, count(DISTINCT e.user_id) AS n FROM public.events e JOIN public.courses c " \
        "ON c.id = e.course_id GROUP BY e.id, c.id", fires],
       ["SELECT e.course_id AS n, count(DISTINCT e.user_id) AS n FROM public.events e GROUP BY e.course_id", fires],
       ["SELECT count(DISTINCT 1) FROM public.events e", "SELECT count(DISTINCT e.kind) FROM public.events e"],
       ["SELECT count(DISTINCT 'a'::text) FROM public.events e", "SELECT count(DISTINCT e.kind) FROM public.events e"],
       ["SELECT count(DISTINCT e.user_id) FROM public.events e WHERE random() < 2",
        "SELECT count(DISTINCT e.user_id) FROM public.events e WHERE e.id < 2"],
       ["SELECT count(DISTINCT e.user_id) FROM public.events e UNION SELECT 1",
        "SELECT count(DISTINCT e.user_id) FROM public.events e"]]
    )
  end
end
