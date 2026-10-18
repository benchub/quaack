# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/literals"
require "quaack/enclave/rewrite_rules/subquery_distinct_removal"
require "quaack/enclave/rewrite_rules/subquery_order_removal"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' subquery_order_removal, on a real server: a
# subquery in FROM or a CTE body loses an ORDER BY with no LIMIT or OFFSET
# when every reader of its rows is blind to their order, and every rewrite
# returns the original's rows.
RSpec.describe Quaack::Enclave::RewriteRules::SubqueryOrderRemoval do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # Equal scores written with different scales (10 and 10.0) and equal
  # intervals written differently ('1 day' and '24 hours'), so a reader
  # that keeps one of several equal values could show which came first.
  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.users (id bigint PRIMARY KEY, name text);
      CREATE TABLE public.posts (id bigint PRIMARY KEY, user_id bigint NOT NULL, title text, score numeric,
                                 ratio float8, wait interval, created_at int NOT NULL);
      INSERT INTO public.users VALUES (1, 'ann'), (2, 'bob'), (3, 'cy');
      INSERT INTO public.posts VALUES
        (1, 1, 'b', 10, 0.1, '1 day', 30), (2, 1, 'a', 10.0, 0.2, '24 hours', 10),
        (3, 2, 'c', 9.5, 0.3, '2 days', 20), (4, 2, 'a', NULL, NULL, NULL, 40), (5, 3, 'd', 7, 0.7, '1 hour', 50);
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  # The rule's rewrites of sql, redacted, with the catalog and a literal
  # oracle for sql's literals.
  def generated(sql, with = catalog)
    query = redacted(sql)
    literals = Quaack::Enclave::RewriteRules::Literals.new(conn, query.placeholder_map)
    rule.rewrites(PgQuery.parse(query.sql), with, literals)
  end

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

  # A subquery in FROM, sorted, for a reader to read as d, and the same
  # without its ORDER BY.
  def ordered = "(SELECT posts.* FROM public.posts ORDER BY posts.created_at DESC) d"
  def kept = "(SELECT posts.* FROM public.posts) d"

  def over_d(select) = "SELECT #{select} FROM #{ordered}"

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["subquery_order_removal",
       "A subquery in FROM or a CTE body loses an ORDER BY that has no LIMIT or OFFSET when every query that " \
       "reads it is blind to the order of its rows: it sorts its own output, or it aggregates with only " \
       "aggregates whose result doesn't depend on the order of their input."]
    )
  end

  it "drops the ORDER BY of a list query that is wrapped to count its rows, and states no assumption" do
    sql = "SELECT count(*) FROM (SELECT posts.* FROM public.posts WHERE posts.user_id = 1 " \
          "ORDER BY posts.created_at DESC) subquery_for_count"

    expect_rewrites(sql, "SELECT count(*) FROM (SELECT posts.* FROM public.posts WHERE posts.user_id = $1) " \
                         "subquery_for_count")
    expect(generated(sql).map(&:assumptions)).to eq([[]])
  end

  it "drops the ORDER BY of a CTE body when every reader is order-blind" do
    cte = "WITH recent AS (SELECT posts.* FROM public.posts ORDER BY posts.created_at DESC) "
    kept = "WITH recent AS (SELECT posts.* FROM public.posts) "

    expect_rewrites("#{cte}SELECT recent.user_id, count(*) FROM recent GROUP BY recent.user_id",
                    "#{kept}SELECT recent.user_id, count(*) FROM recent GROUP BY recent.user_id")
    expect_rewrites("#{cte}SELECT count(*) FROM recent a JOIN recent b ON b.user_id = a.user_id",
                    "#{kept}SELECT count(*) FROM recent a JOIN recent b ON b.user_id = a.user_id")
    expect_rewrites("#{cte}SELECT count(*) FROM recent UNION ALL SELECT count(*) FROM recent",
                    "#{kept}SELECT count(*) FROM recent UNION ALL SELECT count(*) FROM recent")
    expect_refusals(
      [["#{cte}SELECT count(*) FROM recent UNION ALL SELECT recent.id FROM recent",
        "#{cte}SELECT count(*) FROM recent UNION ALL SELECT count(*) FROM recent"],
       ["#{cte}SELECT count(*) FROM recent WHERE recent.id IN (SELECT r.id FROM recent r)",
        "#{cte}SELECT count(*) FROM recent WHERE recent.id IN (SELECT r.id FROM recent r ORDER BY r.id)"]]
    )
  end

  # A table with a schema is the table, even when a CTE has its name, so
  # the EXISTS that reads public.posts doesn't read the CTE.
  it "reads a CTE's name only as a table with no schema" do
    expect_rewrites(
      "WITH posts AS (SELECT p.* FROM public.posts p ORDER BY p.id) SELECT count(*) FROM posts " \
      "WHERE EXISTS (SELECT 1 FROM public.posts q WHERE q.id = posts.id)",
      "WITH posts AS (SELECT p.* FROM public.posts p) SELECT count(*) FROM posts " \
      "WHERE EXISTS (SELECT $1 FROM public.posts q WHERE q.id = posts.id)"
    )
  end

  it "drops the ORDER BY under a reader that sorts its own rows, with or without a LIMIT or OFFSET" do
    expect_rewrites("#{over_d("d.id, d.title")} ORDER BY d.title, d.id",
                    "SELECT d.id, d.title FROM #{kept} ORDER BY d.title, d.id")
    expect_rewrites("#{over_d("d.id")} ORDER BY d.id LIMIT 2 OFFSET 1",
                    "SELECT d.id FROM #{kept} ORDER BY d.id LIMIT $1 OFFSET $2")
    expect_rewrites("SELECT DISTINCT d.user_id FROM #{ordered} ORDER BY d.user_id",
                    "SELECT DISTINCT d.user_id FROM #{kept} ORDER BY d.user_id")
  end

  it "takes every aggregate whose result doesn't follow its input order" do
    ["count(*)", "count(DISTINCT d.user_id)", "pg_catalog.count(d.id)", "bool_and(d.score > 9)",
     "bool_or(d.score > 9)", "every(d.score > 9)", "min(d.created_at)", "max(d.id)", "max(d.title)",
     "sum(d.user_id)", "avg(d.user_id)", "sum(d.score)", "avg(d.score)", "round(avg(d.score), 2)",
     "string_agg(d.title, ',' ORDER BY d.title, d.id)", "array_agg(d.ratio ORDER BY d.id)",
     "percentile_cont(0.5) WITHIN GROUP (ORDER BY d.created_at)", "count(*) FILTER (WHERE d.user_id = 1)",
     "count(*) + 1"].each do |aggregate|
      expect_rewrites(over_d(aggregate), redacted(over_d(aggregate)).sql.sub(ordered, kept))
    end
  end

  it "takes a GROUP BY of keys whose equal values look the same, and HAVING" do
    expect_rewrites("#{over_d("d.user_id, count(*)")} GROUP BY d.user_id",
                    "SELECT d.user_id, count(*) FROM #{kept} GROUP BY d.user_id")
    expect_rewrites("#{over_d("d.user_id, count(*)")} GROUP BY 1 HAVING count(*) > 1",
                    "SELECT d.user_id, count(*) FROM #{kept} GROUP BY 1 HAVING count(*) > $1")
    expect_rewrites("#{over_d("d.created_at / 20, max(d.id)")} GROUP BY 1 ORDER BY 1",
                    "SELECT d.created_at / $1, max(d.id) FROM #{kept} GROUP BY 1 ORDER BY 1")
  end

  it "rewrites each subquery once, from the original, in tree order" do
    first = "(SELECT posts.user_id FROM public.posts ORDER BY posts.id) a"
    second = "(SELECT users.id FROM public.users ORDER BY users.name) b"
    expect_rewrites(
      "SELECT count(*) FROM #{first} JOIN #{second} ON b.id = a.user_id",
      "SELECT count(*) FROM (SELECT posts.user_id FROM public.posts) a JOIN #{second} ON b.id = a.user_id",
      "SELECT count(*) FROM #{first} JOIN (SELECT users.id FROM public.users) b ON b.id = a.user_id"
    )
  end

  it "drops the ORDER BY of a LATERAL subquery, a set operation, and a VALUES list in FROM" do
    expect_rewrites(
      "SELECT users.id, count(*) FROM public.users, LATERAL (SELECT posts.id FROM public.posts " \
      "WHERE posts.user_id = users.id ORDER BY posts.created_at) p GROUP BY users.id",
      "SELECT users.id, count(*) FROM public.users, LATERAL (SELECT posts.id FROM public.posts " \
      "WHERE posts.user_id = users.id) p GROUP BY users.id"
    )
    expect_rewrites(
      "SELECT count(*) FROM (SELECT posts.id FROM public.posts UNION ALL SELECT users.id FROM public.users " \
      "ORDER BY 1) u",
      "SELECT count(*) FROM (SELECT posts.id FROM public.posts UNION ALL SELECT users.id FROM public.users) u"
    )
    expect_rewrites("SELECT count(*) FROM (VALUES (1), (2) ORDER BY 1) v(x)",
                    "SELECT count(*) FROM (VALUES ($1), ($2)) v(x)")
  end

  # Under a nondeterministic collation, max can keep 'a' or 'A', and which
  # one it keeps follows its input order. Text is safe only when no
  # column, domain, or range uses such a collation, and no COLLATE names
  # one.
  it "takes min or max of text only when no nondeterministic collation could compare it" do
    plain = over_d("max(d.title)")
    expect(rewritten(plain).size).to eq(1)
    expect(rewritten(over_d("max(d.title COLLATE \"C\")"))).to eq([])

    conn.exec("CREATE COLLATION public.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false); " \
              "CREATE TABLE public.labels (name text COLLATE public.ci)")
    later = Quaack::Enclave::RewriteRules::Catalog.new(conn)
    expect(generated(plain, later)).to eq([])
    expect(generated(over_d("max(d.id)"), later).size).to eq(1)
  end

  it "leaves alone a subquery whose reader can see its order" do
    sorted = "#{over_d("d.id")} ORDER BY d.id"
    counted = over_d("count(*)")
    expect_refusals(
      [[over_d("d.id"), sorted],
       ["SELECT count(*) FROM (SELECT d.id FROM #{ordered}) e", counted],
       ["SELECT ARRAY(#{over_d("d.id")})", "SELECT ARRAY(#{sorted})"],
       ["#{over_d("d.id, row_number() OVER ()")} ORDER BY d.id", sorted],
       ["#{over_d("count(*) OVER ()")} ORDER BY 1", sorted],
       ["#{over_d("d.id")} WINDOW w AS () ORDER BY d.id", sorted],
       ["#{over_d("d.user_id, count(*)")} GROUP BY d.user_id LIMIT 2",
        "#{over_d("d.user_id, count(*)")} GROUP BY d.user_id"],
       ["#{over_d("d.user_id, count(*)")} GROUP BY d.user_id OFFSET 1",
        "#{over_d("d.user_id, count(*)")} GROUP BY d.user_id ORDER BY 1 OFFSET 1"],
       ["#{over_d("DISTINCT ON (d.user_id) d.id")} ORDER BY d.user_id", sorted],
       [over_d("d.id IN (SELECT count(*) FROM public.users)"), counted]]
    )
  end

  # Each of these keeps a value its input order picks: the order of an
  # array or a string, a float's rounding, which of two equal values it
  # shows (10 or 10.0, '1 day' or '24 hours'), or the overflow of an
  # interval's sum.
  it "leaves alone a reader whose aggregate, GROUP BY, or DISTINCT follows its input order" do
    counted = over_d("count(*)")
    expect_refusals(
      [*["array_agg(d.id)", "string_agg(d.title, ',')", "json_agg(d.id)", "sum(d.ratio)", "avg(d.ratio)",
         "sum(d.wait)", "max(d.score)", "min(d.wait)", "max(d.ratio)", "count(*), (SELECT string_agg(d.title, ','))",
         "count(*), (SELECT max(d.id))"].map { [over_d(it), counted] },
       ["#{over_d("d.score, count(*)")} GROUP BY d.score", "#{over_d("d.user_id, count(*)")} GROUP BY d.user_id"],
       ["#{over_d("d.wait, count(*)")} GROUP BY 1", "#{over_d("d.user_id, count(*)")} GROUP BY 1"],
       ["SELECT DISTINCT d.score FROM #{ordered} ORDER BY d.score",
        "SELECT DISTINCT d.user_id FROM #{ordered} ORDER BY d.user_id"],
       ["SELECT DISTINCT d.* FROM (SELECT posts.id, posts.user_id FROM public.posts ORDER BY posts.id) d ORDER BY 1",
        "SELECT DISTINCT d.id, d.user_id FROM (SELECT posts.id, posts.user_id FROM public.posts ORDER BY posts.id) d " \
        "ORDER BY 1"]]
    )
    # Postgres refuses a GROUP BY number outside the select list,
    # so intake never hands the rule one, but the rule refuses it too.
    expect([generated("#{over_d("d.user_id, count(*)")} GROUP BY 3"),
            generated("#{over_d("d.user_id, count(*)")} GROUP BY 0")]).to eq([[], []])
  end

  # The rule asks Postgres for the types a sum, min, max, GROUP BY, or
  # DISTINCT reads, which it can do for the top-level SELECT alone.
  it "types a reader's sums and keys only at the top level" do
    cte = "WITH a AS (SELECT posts.* FROM public.posts ORDER BY posts.id), "
    expect_refusals(
      [["#{cte}b AS (SELECT a.user_id, count(*) FROM a GROUP BY a.user_id) SELECT b.* FROM b",
        "#{cte}b AS (SELECT count(*) AS n FROM a) SELECT b.* FROM b"],
       ["#{cte}b AS (SELECT max(a.id) AS n FROM a) SELECT b.* FROM b",
        "#{cte}b AS (SELECT count(*) AS n FROM a) SELECT b.* FROM b"],
       ["SELECT (SELECT sum(d.user_id) FROM #{ordered})", "SELECT (SELECT count(*) FROM #{ordered})"]]
    )
  end

  # Postgres types a placeholder left untyped as text, or as the other
  # side of an operator's, but the literal 1.0 is a numeric, so
  # CASE ... THEN 1.0 ELSE 1.00 END is a numeric, whose GROUP BY keeps 1.0
  # or 1.00, whichever comes first. The literal oracle prepares the
  # reader's expressions with the literals' own types to catch it.
  it "checks the types a reader's constants give with the literals' own types" do
    banded = "CASE WHEN d.score > 9 THEN %s ELSE %s END AS band, count(*)"
    expect_refusals(
      [["#{over_d(format(banded, "1.0", "1.00"))} GROUP BY 1",
        "#{over_d(format(banded, "'high'", "'low'"))} GROUP BY 1"],
       [over_d("max(d.created_at * 1.5)"), over_d("max(d.created_at * 2)")],
       [over_d("sum(d.created_at * 1.5)"), over_d("sum(d.created_at * 2)")]]
    )
    refused = "#{over_d(format(banded, "1.0", "1.00"))} GROUP BY 1"
    expect([conn.exec(refused).values, conn.exec(refused.sub(" DESC", "")).values])
      .to eq([[%w[1.00 5]], [%w[1.0 5]]])
  end

  # Postgres describes a domain's value by its base type, but the literal
  # oracle's btarraycmp tells the domain from it, so the rule refuses it.
  it "leaves alone a min or max of a domain's value" do
    conn.exec("CREATE DOMAIN public.rank AS integer; ALTER TABLE public.posts ADD COLUMN rank public.rank; " \
              "UPDATE public.posts SET rank = id")
    expect_refusals([[over_d("max(d.rank)"), over_d("max(d.id)")]])
  end

  # With no literal oracle, as when the generator runs without one, the
  # rule can't check those types, so it takes only readers that need none.
  it "takes only readers that need no types when it has no literal oracle" do
    [[over_d("max(d.id)"), 0], [over_d("sum(d.user_id)"), 0], ["#{over_d("d.user_id, count(*)")} GROUP BY 1", 0],
     [over_d("count(*)"), 1], ["#{over_d("d.id")} ORDER BY d.id", 1]].each do |sql, count|
      expect(rule.rewrites(PgQuery.parse(redacted(sql).sql), catalog).size).to eq(count), sql
    end
  end

  # A sum over text that concatenates follows its input order, and a bare
  # sum(text) calls it. Only pg_catalog's own aggregates are trusted.
  it "leaves alone an aggregate that a schema other than pg_catalog also defines" do
    conn.exec("CREATE AGGREGATE public.sum(text) (SFUNC = textcat, STYPE = text)")
    expect_refusals(
      [[over_d("sum(d.title)"), over_d("pg_catalog.count(*)")],
       [over_d("sum(d.user_id)"), over_d("pg_catalog.sum(d.user_id)")],
       [over_d("public.sum(d.title)"), over_d("pg_catalog.max(d.id)")]]
    )
  end

  it "leaves alone a body with a LIMIT, OFFSET, FETCH, or DISTINCT ON" do
    plain = "SELECT count(*) FROM (SELECT posts.user_id FROM public.posts ORDER BY posts.user_id) d"
    expect_refusals(
      [[plain.sub(") d", " LIMIT 3) d"), plain],
       [plain.sub(") d", " OFFSET 1) d"), plain],
       [plain.sub(") d", " FETCH FIRST 2 ROWS WITH TIES) d"), plain],
       [plain.sub("SELECT posts.user_id", "SELECT DISTINCT ON (posts.user_id) posts.user_id"), plain]]
    )
  end

  # SupportedSql refuses a locking clause, so intake never hands the rule
  # one, and the query goes to the rule unredacted.
  it "leaves alone a body with a locking clause" do
    locked = "SELECT count(*) FROM (SELECT posts.id FROM public.posts ORDER BY posts.id FOR UPDATE) d"
    expect(conn.exec(locked).ntuples).to be_positive
    expect(rule.rewrites(PgQuery.parse(locked), catalog)).to eq([])
    expect(rule.rewrites(PgQuery.parse(locked.sub(" FOR UPDATE", "")), catalog).size).to eq(1)
  end

  # An aggregate in the ORDER BY makes a SELECT with no GROUP BY give one
  # row, so dropping it would give every row.
  it "leaves alone a body whose select list or ORDER BY isn't one value per row" do
    plain = "SELECT count(*) FROM (SELECT posts.user_id FROM public.posts ORDER BY posts.user_id) d"
    in_order = "SELECT count(*) FROM (SELECT 1 AS one FROM public.posts ORDER BY count(*)) d"
    expect_refusals(
      [[in_order, plain],
       ["SELECT count(*) FROM (SELECT posts.user_id, count(*) FROM public.posts GROUP BY posts.user_id " \
        "ORDER BY 2) d", plain],
       ["SELECT count(*) FROM (SELECT posts.user_id FROM public.posts GROUP BY posts.user_id " \
        "HAVING count(*) > 1 ORDER BY 1) d", plain],
       ["SELECT count(*) FROM (SELECT unnest(ARRAY[posts.id, posts.user_id]) FROM public.posts ORDER BY 1) d",
        plain],
       ["SELECT count(*) FROM (SELECT row_number() OVER () FROM public.posts ORDER BY posts.id) d", plain]]
    )
    expect(conn.exec(in_order).values).to eq([["1"]])
    expect(conn.exec(in_order.sub(" ORDER BY count(*)", "")).values).to eq([["5"]])
  end

  it "leaves alone a statement that calls a volatile function" do
    plain = over_d("count(*)")
    expect_refusals(
      [[over_d("count(*) + floor(random())::int"), plain],
       ["SELECT count(*) FROM (SELECT posts.id FROM public.posts ORDER BY random()) d", plain]]
    )
  end

  # SupportedSql refuses a data-modifying CTE and any statement but a
  # SELECT, so the query goes to the rule unredacted.
  it "leaves alone a RECURSIVE WITH, a CTE name used twice, and a statement that isn't a SELECT" do
    cte = "WITH c AS (SELECT posts.id FROM public.posts ORDER BY posts.id) "
    plain = "#{cte}SELECT count(*) FROM c"
    expect_refusals(
      [["WITH RECURSIVE c AS (SELECT posts.id FROM public.posts ORDER BY posts.id) SELECT count(*) FROM c", plain],
       ["#{plain} WHERE EXISTS (WITH c AS (SELECT 1 AS id) SELECT count(*) FROM c)",
        "#{plain} WHERE EXISTS (WITH e AS (SELECT 1 AS id) SELECT count(*) FROM e)"]]
    )
    expect(rule.rewrites(PgQuery.parse("CREATE VIEW public.v AS #{plain}"), catalog)).to eq([])
    expect(rule.rewrites(PgQuery.parse(plain), catalog).size).to eq(1)
    expect(rule.rewrites(PgQuery.parse(plain.sub("WITH ", "WITH w AS (DELETE FROM public.users RETURNING id), ")),
                         catalog)).to eq([])
  end

  # subquery_distinct_removal drops the ORDER BY of an IN subquery and of
  # an arm under a set operation, so this rule leaves those to it, and
  # neither rule takes the other's subqueries.
  it "leaves the ORDER BYs that subquery_distinct_removal drops to it" do
    other = Quaack::Enclave::RewriteRules::SubqueryDistinctRemoval.new
    [["SELECT users.id FROM public.users WHERE users.id IN (SELECT posts.user_id FROM public.posts " \
      "ORDER BY posts.id)", 1, 0],
     ["SELECT users.id FROM public.users UNION (SELECT posts.user_id FROM public.posts ORDER BY posts.id)", 1, 0],
     ["SELECT users.id FROM public.users WHERE users.id IN (SELECT d.user_id FROM #{ordered})", 0, 0],
     [over_d("count(*)"), 0, 1]].each do |sql, theirs, ours|
      parse = PgQuery.parse(redacted(sql).sql)
      expect([other.rewrites(parse, catalog).size, generated(sql).size]).to eq([theirs, ours]), sql
    end
  end
end
