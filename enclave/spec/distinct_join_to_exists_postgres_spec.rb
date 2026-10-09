# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/relation_qualifier"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' distinct_join_to_exists, on a real server: what it writes,
# that its output returns the rows its input does on data that would show a
# wrong transformation, and that it only fires when the catalog proves a
# selected column of the kept table unique and not null and the shape is one
# it can move.
RSpec.describe Quaack::Enclave::RewriteRules::DistinctJoinToExists do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # Assignments 1, 2, 5, and 6 have a done submission in context 10: 1 has
  # three, so a join in place of the EXISTS would give it three times, and 2
  # has one, beside a draft. Each other assignment fails one thing:
  #   3   has no submission
  #   4   its only submission is a draft (a moved predicate)
  #   7   another context (a kept predicate)
  # 5 and 6 are equal in title, ctx, loose, and code (NULL), so a DISTINCT
  # over those alone merges them. Submission 901 has no assignment.
  # Only 1 and 5 have a done submission with a 'hi' comment: 2's 'hi' is on
  # its draft, and its done submission's comment is 'no'.
  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.assignments (id int PRIMARY KEY, title text, ctx int, code text UNIQUE,
                                       loose int NOT NULL, slug text NOT NULL UNIQUE, tag text);
      CREATE UNIQUE INDEX assignments_tag ON public.assignments (tag) NULLS NOT DISTINCT;
      CREATE TABLE public.submissions (id int PRIMARY KEY, a_id int, state text);
      CREATE TABLE public.comments (id int PRIMARY KEY, s_id int, body text);
      CREATE TABLE public.pairs (x int, y int, PRIMARY KEY (x, y));
      CREATE TABLE public."my a" (id int PRIMARY KEY, title text);
      INSERT INTO public.assignments VALUES
        (1, 'one', 10, 'a', 1, 's1', 't1'), (2, 'two', 10, 'b', 2, 's2', 't2'),
        (3, 'three', 10, 'c', 3, 's3', NULL), (4, 'four', 10, 'd', 4, 's4', 't4'),
        (5, 'twin', 10, NULL, 5, 's5', 't5'), (6, 'twin', 10, NULL, 5, 's6', 't6'),
        (7, 'seven', 11, 'g', 7, 's7', 't7');
      INSERT INTO public.submissions VALUES
        (101, 1, 'done'), (102, 1, 'done'), (103, 1, 'done'), (201, 2, 'done'), (202, 2, 'draft'),
        (401, 4, 'draft'), (501, 5, 'done'), (601, 6, 'done'), (701, 7, 'done'), (901, NULL, 'done');
      INSERT INTO public.comments VALUES
        (1, 101, 'hi'), (2, 101, 'hi'), (3, 201, 'no'), (4, 202, 'hi'), (5, 501, 'hi'), (6, 401, 'hi');
      INSERT INTO public.pairs VALUES (1, 1), (1, 2);
      INSERT INTO public."my a" VALUES (1, 'one');
      CREATE FUNCTION public.upto(int, int) RETURNS SETOF int IMMUTABLE LANGUAGE sql
        AS 'SELECT generate_series($1, $2)';
      CREATE OPERATOR public.### (LEFTARG = int, RIGHTARG = int, FUNCTION = public.upto);
      CREATE FUNCTION public.both(public.assignments) RETURNS SETOF text IMMUTABLE LANGUAGE sql
        AS 'SELECT unnest(ARRAY[$1.title, $1.title])';
      CREATE SCHEMA elsewhere;
      CREATE FUNCTION public.shout(text) RETURNS text IMMUTABLE LANGUAGE sql AS 'SELECT upper($1)';
      CREATE FUNCTION public.said(public.comments) RETURNS text IMMUTABLE LANGUAGE sql AS 'SELECT $1.body';
      CREATE FUNCTION public.stamp(public.comments) RETURNS float VOLATILE LANGUAGE sql AS 'SELECT random()';
      CREATE FUNCTION elsewhere.shout(text) RETURNS SETOF text IMMUTABLE LANGUAGE sql AS 'SELECT upper($1)';
    SQL
  end

  after do
    conn.close
    production.drop
  end

  # The rule's rewrites of sql, each as SQL.
  def rewritten(sql)
    rule.rewrites(PgQuery.parse(sql), catalog).map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  def ordered_rows(sql, params = []) = conn.exec_params(sql, params).values
  def rows(sql, params = []) = ordered_rows(sql, params).sort_by(&:to_s)

  # The original's rows, once every rewrite has been checked to return the
  # same multiset of them.
  def same_rows(sql, rewrites, params = [])
    expected = rows(sql, params)
    expect(rewrites).not_to be_empty
    rewrites.each { expect(rows(it, params)).to eq(expected), "#{it} returns other rows" }
    expected
  end

  # The same, for rows in the order the server gives them.
  def same_ordered_rows(sql, rewrites, params = [])
    expected = ordered_rows(sql, params)
    expect(rewrites).not_to be_empty
    rewrites.each { expect(ordered_rows(it, params)).to eq(expected), "#{it} returns other rows" }
    expected
  end

  # As input qualifies it.
  def qualified(sql) = Quaack::Enclave::RelationQualifier.qualify(sql, nil, conn).sql

  fires = "SELECT DISTINCT a.id, a.title FROM public.assignments a JOIN public.submissions s ON s.a_id = a.id " \
          "WHERE a.ctx = 10 AND s.state = 'done'"
  let(:fires) { fires }

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["distinct_join_to_exists",
       "A SELECT DISTINCT over a join that reads only one table, with a unique, not-null key of that table among " \
       "its columns, becomes that table alone with an EXISTS on the other tables, and no DISTINCT."]
    )
  end

  it "keeps the one table, moves the others and their conditions into an EXISTS, and drops the DISTINCT" do
    rewrites = rewritten(fires)

    expect(rewrites).to eq(
      ["SELECT a.id, a.title FROM public.assignments a WHERE a.ctx = 10 AND " \
       "EXISTS (SELECT 1 FROM public.submissions s WHERE s.a_id = a.id AND s.state = 'done')"]
    )
    expect(same_rows(fires, rewrites)).to eq([%w[1 one], %w[2 two], %w[5 twin], %w[6 twin]])
  end

  it "states the key unique and not null, in assumption-check's vocabulary" do
    expect(rule.rewrites(PgQuery.parse(fires), catalog).map(&:assumptions)).to eq(
      [[{ "kind" => "unique", "table" => "public.assignments", "columns" => ["id"] },
        { "kind" => "not_null", "table" => "public.assignments", "column" => "id" }]]
    )
  end

  it "doesn't change the parse it was given" do
    parse = PgQuery.parse(fires)
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

    expect(rule.rewrites(parse, catalog).size).to eq(1)

    expect(parse.tree).to eq(before)
  end

  it "takes the ORM's shape: unaliased tables, a star, parameters, and ORDER BY the key with a LIMIT" do
    sql = qualified("SELECT DISTINCT assignments.* FROM assignments INNER JOIN submissions ON " \
                    "submissions.a_id = assignments.id WHERE assignments.ctx = $1 AND submissions.state = $2 " \
                    "ORDER BY assignments.id DESC LIMIT 3")

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT assignments.* FROM public.assignments WHERE assignments.ctx = $1 AND " \
       "EXISTS (SELECT 1 FROM public.submissions WHERE submissions.a_id = assignments.id AND " \
       "submissions.state = $2) ORDER BY assignments.id DESC LIMIT 3"]
    )
    expect(same_ordered_rows(sql, rewrites, [10, "done"]).map(&:first)).to eq(%w[6 5 2])
  end

  it "finds a star's key in the catalog, and states it" do
    sql = "SELECT DISTINCT s.* FROM public.submissions s JOIN public.comments c ON c.s_id = s.id"

    expect(rule.rewrites(PgQuery.parse(sql), catalog).map(&:assumptions)).to eq(
      [[{ "kind" => "unique", "table" => "public.submissions", "columns" => ["id"] },
        { "kind" => "not_null", "table" => "public.submissions", "column" => "id" }]]
    )
    expect(same_rows(sql, rewritten(sql)).map(&:first)).to eq(%w[101 201 202 401 501])
  end

  it "takes the first selected column the catalog proves a key, which needn't be the primary key" do
    sql = "SELECT DISTINCT a.title, a.code, a.slug FROM public.assignments a JOIN public.submissions s " \
          "ON s.a_id = a.id WHERE s.state = 'done'"

    expect(rule.rewrites(PgQuery.parse(sql), catalog).map(&:assumptions)).to eq(
      [[{ "kind" => "unique", "table" => "public.assignments", "columns" => ["slug"] },
        { "kind" => "not_null", "table" => "public.assignments", "column" => "slug" }]]
    )
    expect(same_rows(sql, rewritten(sql)).map(&:last).sort).to eq(%w[s1 s2 s5 s6 s7])
  end

  # id and slug are both proven keys of assignments.
  {
    "a.id, a.slug" => "id",
    "a.slug, a.id" => "slug",
    "a.title, a.slug, a.id" => "slug",
    "a.*" => "id"
  }.each do |list, key|
    it "states the first of two proven keys in the select list: #{key} for #{list}" do
      sql = "SELECT DISTINCT #{list} FROM public.assignments a JOIN public.submissions s ON s.a_id = a.id"

      expect(rule.rewrites(PgQuery.parse(sql), catalog).map(&:assumptions)).to eq(
        [[{ "kind" => "unique", "table" => "public.assignments", "columns" => [key] },
          { "kind" => "not_null", "table" => "public.assignments", "column" => key }]]
      )
    end
  end

  it "puts every other table in one EXISTS, so their conditions are met by the same rows" do
    sql = "SELECT DISTINCT a.id FROM public.assignments a JOIN public.submissions s ON s.a_id = a.id " \
          "JOIN public.comments c ON c.s_id = s.id WHERE s.state = 'done' AND c.body = 'hi'"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT a.id FROM public.assignments a WHERE EXISTS (SELECT 1 FROM public.submissions s, public.comments c " \
       "WHERE s.a_id = a.id AND c.s_id = s.id AND s.state = 'done' AND c.body = 'hi')"]
    )
    expect(same_rows(sql, rewrites)).to eq([["1"], ["5"]])
  end

  it "moves a join's condition on the kept table alone to the WHERE, wherever the kept table is in the FROM" do
    sql = "SELECT DISTINCT a.id FROM public.submissions s JOIN public.assignments a ON s.a_id = a.id AND a.ctx = 10 " \
          "WHERE s.state = 'draft'"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT a.id FROM public.assignments a WHERE a.ctx = 10 AND " \
       "EXISTS (SELECT 1 FROM public.submissions s WHERE s.a_id = a.id AND s.state = 'draft')"]
    )
    expect(same_rows(sql, rewrites)).to eq([["2"], ["4"]])
  end

  it "keeps a condition that reads both sides, such as an OR across them, whole inside the EXISTS" do
    sql = "SELECT DISTINCT a.id FROM public.assignments a, public.submissions s " \
          "WHERE s.a_id = a.id AND (a.ctx = 11 OR s.state = 'draft')"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT a.id FROM public.assignments a WHERE " \
       "EXISTS (SELECT 1 FROM public.submissions s WHERE s.a_id = a.id AND (a.ctx = 11 OR s.state = 'draft'))"]
    )
    expect(same_rows(sql, rewrites)).to eq([["2"], ["4"], ["7"]])
  end

  it "keeps a second read of the kept table apart, under its own name" do
    sql = "SELECT DISTINCT a.id FROM public.assignments a JOIN public.assignments b " \
          "ON b.title = a.title AND b.id <> a.id"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT a.id FROM public.assignments a WHERE " \
       "EXISTS (SELECT 1 FROM public.assignments b WHERE b.title = a.title AND b.id <> a.id)"]
    )
    expect(same_rows(sql, rewrites)).to eq([["5"], ["6"]])
  end

  # A subquery in a condition on the kept table alone stays in the WHERE,
  # unchanged, beside the EXISTS. Its own tables' columns are its own, so a
  # name it shares with a removed table doesn't make it read that table.
  describe "a subquery in a condition on the kept table" do
    {
      "an uncorrelated IN" =>
        ["#{fires} AND a.id IN (SELECT x.a_id FROM public.submissions x WHERE x.state = 'draft')",
         "a.id IN (SELECT x.a_id FROM public.submissions x WHERE x.state = 'draft')",
         [%w[2 two]]],
      "an EXISTS that reads no outer table" =>
        ["#{fires} AND EXISTS (SELECT 1 FROM public.comments c WHERE c.body = 'no')",
         "EXISTS (SELECT 1 FROM public.comments c WHERE c.body = 'no')",
         [%w[1 one], %w[2 two], %w[5 twin], %w[6 twin]]],
      "a NOT EXISTS correlated with the kept table" =>
        ["#{fires} AND NOT EXISTS (SELECT * FROM public.submissions x WHERE x.a_id = a.id AND x.state = 'draft')",
         "NOT EXISTS (SELECT * FROM public.submissions x WHERE x.a_id = a.id AND x.state = 'draft')",
         [%w[1 one], %w[5 twin], %w[6 twin]]],
      "a NOT IN whose subquery gives a NULL" =>
        ["#{fires} AND a.ctx NOT IN (SELECT x.a_id FROM public.submissions x)",
         "NOT a.ctx IN (SELECT x.a_id FROM public.submissions x)",
         []],
      "a NOT IN of a NULL column" =>
        ["#{fires} AND a.code NOT IN (SELECT c.body FROM public.comments c)",
         "NOT a.code IN (SELECT c.body FROM public.comments c)",
         [%w[1 one], %w[2 two]]],
      "a scalar subquery that gives NULL" =>
        ["#{fires} AND a.tag IS DISTINCT FROM (SELECT x.state FROM public.submissions x WHERE x.id = 0)",
         "a.tag IS DISTINCT FROM (SELECT x.state FROM public.submissions x WHERE x.id = 0)",
         [%w[1 one], %w[2 two], %w[5 twin], %w[6 twin]]],
      "bare columns of its own table, one a name both outer tables have" =>
        ["#{fires} AND a.id IN (SELECT a_id FROM public.submissions x WHERE id > 200 AND state = 'done')",
         "a.id IN (SELECT a_id FROM public.submissions x WHERE id > 200 AND state = 'done')",
         [%w[2 two], %w[5 twin], %w[6 twin]]],
      "its own table under a removed table's name" =>
        ["#{fires} AND a.id IN (SELECT s.a_id FROM public.submissions s WHERE s.state = 'draft')",
         "a.id IN (SELECT s.a_id FROM public.submissions s WHERE s.state = 'draft')",
         [%w[2 two]]],
      "a nested subquery correlated with the kept table and its parent" =>
        ["#{fires} AND EXISTS (SELECT 1 FROM public.submissions x WHERE x.a_id = a.id AND " \
         "EXISTS (SELECT c.* FROM public.comments c WHERE c.s_id = x.id AND c.body = 'hi' AND a.ctx = 10))",
         "EXISTS (SELECT 1 FROM public.submissions x WHERE x.a_id = a.id AND " \
         "EXISTS (SELECT c.* FROM public.comments c WHERE c.s_id = x.id AND c.body = 'hi' AND a.ctx = 10))",
         [%w[1 one], %w[2 two], %w[5 twin]]],
      "a bare column only the kept table has, inside the subquery" =>
        ["#{fires} AND EXISTS (SELECT 1 FROM public.comments c WHERE c.s_id = 101 AND title = 'one')",
         "EXISTS (SELECT 1 FROM public.comments c WHERE c.s_id = 101 AND title = 'one')",
         [%w[1 one]]],
      "a function of its own table's row, written as a column" =>
        ["#{fires} AND EXISTS (SELECT 1 FROM public.comments c, public.submissions x " \
         "WHERE c.s_id = x.id AND x.a_id = a.id AND c.said = 'hi')",
         "EXISTS (SELECT 1 FROM public.comments c, public.submissions x " \
         "WHERE c.s_id = x.id AND x.a_id = a.id AND c.said = 'hi')",
         [%w[1 one], %w[2 two], %w[5 twin]]],
      "a bare column of the nearest subquery, which its parent has twice" =>
        ["#{fires} AND EXISTS (SELECT 1 FROM public.comments c, public.submissions x " \
         "WHERE c.s_id = x.id AND x.a_id = a.id AND " \
         "EXISTS (SELECT 1 FROM public.comments d WHERE d.s_id = x.id AND id > 1))",
         "EXISTS (SELECT 1 FROM public.comments c, public.submissions x " \
         "WHERE c.s_id = x.id AND x.a_id = a.id AND " \
         "EXISTS (SELECT 1 FROM public.comments d WHERE d.s_id = x.id AND id > 1))",
         [%w[1 one], %w[2 two], %w[5 twin]]],
      "a row comparison of its own column and the kept table's" =>
        ["#{fires} AND EXISTS (SELECT 1 FROM public.comments c WHERE (c.s_id, a.id) = (501, 5))",
         "EXISTS (SELECT 1 FROM public.comments c WHERE (c.s_id, a.id) = (501, 5))",
         [%w[5 twin]]]
    }.each do |what, (sql, kept, expected)|
      it "keeps #{what} in the WHERE, and gives the same rows" do
        rewrites = rewritten(sql)

        expect(rewrites).to eq(
          ["SELECT a.id, a.title FROM public.assignments a WHERE a.ctx = 10 AND #{kept} AND " \
           "EXISTS (SELECT 1 FROM public.submissions s WHERE s.a_id = a.id AND s.state = 'done')"]
        )
        expect(same_rows(sql, rewrites)).to eq(expected)
      end
    end

    it "keeps one in a join condition in the WHERE" do
      sql = "SELECT DISTINCT a.id, a.title FROM public.assignments a JOIN public.submissions s " \
            "ON s.a_id = a.id AND a.id IN (SELECT x.a_id FROM public.submissions x WHERE x.state = 'draft') " \
            "WHERE s.state = 'done'"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT a.id, a.title FROM public.assignments a WHERE " \
         "a.id IN (SELECT x.a_id FROM public.submissions x WHERE x.state = 'draft') AND " \
         "EXISTS (SELECT 1 FROM public.submissions s WHERE s.a_id = a.id AND s.state = 'done')"]
      )
      expect(same_rows(sql, rewrites)).to eq([%w[2 two]])
    end
  end

  it "leaves an EXISTS with no condition for a join that has none" do
    sql = "SELECT DISTINCT p.x, p.y, p.x FROM public.pairs p CROSS JOIN public.comments c"
    keyed = "SELECT DISTINCT a.id FROM public.assignments a CROSS JOIN public.comments c WHERE a.ctx = 11"

    expect(rewritten(sql)).to eq(
      ["SELECT p.x, p.y, p.x FROM public.pairs p WHERE EXISTS (SELECT 1 FROM public.comments c)"]
    )
    expect(same_rows(sql, rewritten(sql))).to eq([%w[1 1 1], %w[1 2 1]])
    expect(rewritten(keyed)).to eq(
      ["SELECT a.id FROM public.assignments a WHERE a.ctx = 11 AND EXISTS (SELECT 1 FROM public.comments c)"]
    )
    expect(same_rows(keyed, rewritten(keyed))).to eq([["7"]])
  end

  it "keeps the ORDER BY, by column or by position, and the rows come in the same order" do
    by_column = "#{fires} ORDER BY a.title DESC, a.id DESC"
    by_position = "#{fires} ORDER BY 2, 1"

    expect(rewritten(by_column).first).to end_with("AND s.state = 'done') ORDER BY a.title DESC, a.id DESC")
    expect(same_ordered_rows(by_column, rewritten(by_column)).map(&:first)).to eq(%w[2 6 5 1])
    expect(same_ordered_rows(by_position, rewritten(by_position)).map(&:first)).to eq(%w[1 5 6 2])
  end

  it "takes a LIMIT and OFFSET when the ORDER BY holds a selected key, which makes the order total" do
    sql = "SELECT DISTINCT a.id, a.title, a.slug FROM public.assignments a JOIN public.submissions s " \
          "ON s.a_id = a.id WHERE s.state = 'done' ORDER BY a.title DESC, a.slug DESC LIMIT 2 OFFSET 1"

    rewrites = rewritten(sql)

    expect(rewrites.first).to end_with("ORDER BY a.title DESC, a.slug DESC LIMIT 2 OFFSET 1")
    expect(rule.rewrites(PgQuery.parse(sql), catalog).first.assumptions).to eq(
      [{ "kind" => "unique", "table" => "public.assignments", "columns" => ["slug"] },
       { "kind" => "not_null", "table" => "public.assignments", "column" => "slug" }]
    )
    expect(same_ordered_rows(sql, rewrites).map(&:first)).to eq(%w[6 5])
  end

  # Task 20261003-35: Rails sends ORDER BY id LIMIT n. A bare name in an
  # ORDER BY is an output column's first, so it only counts as the key when
  # it's the key.
  describe "a bare key column in the ORDER BY under a LIMIT" do
    from = "FROM public.assignments a JOIN public.submissions s ON s.a_id = a.id WHERE s.state = 'done'"

    {
      "a selected key" => "SELECT DISTINCT a.id, a.title #{from} ORDER BY id LIMIT 2 OFFSET 1",
      "a star, where both tables have the column" => "SELECT DISTINCT a.* #{from} ORDER BY id DESC LIMIT 2",
      "a key that an alias names for itself" => "SELECT DISTINCT a.id AS id, a.title #{from} ORDER BY id LIMIT 2",
      "a key another table doesn't have" => "SELECT DISTINCT a.slug, a.title #{from} ORDER BY slug LIMIT 2"
    }.each do |what, sql|
      it "is taken for #{what}, with the rows in the same order" do
        rewrites = rewritten(sql)

        expect(rewrites.size).to eq(1)
        expect(rewrites.first).to include("FROM public.assignments a WHERE EXISTS")
        expect(same_ordered_rows(sql, rewrites)).not_to be_empty
      end
    end

    {
      "an output name is another column's" =>
        "SELECT DISTINCT a.title AS id, a.id AS k #{from} ORDER BY id LIMIT 2",
      "an output name is the key's, for another column" =>
        "SELECT DISTINCT a.slug AS id, a.id AS k #{from} ORDER BY id LIMIT 2",
      "an unaliased expression might be named for the column" =>
        "SELECT DISTINCT a.title || 'x', a.id #{from} ORDER BY id LIMIT 2",
      "the name is both tables' and the select list doesn't name it" =>
        "SELECT DISTINCT a.slug, a.title #{from} ORDER BY id LIMIT 2",
      "the name is not the key" => "SELECT DISTINCT a.id, a.title #{from} ORDER BY title LIMIT 2",
      "the name is a table's" => "SELECT DISTINCT a.id, a.title #{from} ORDER BY a LIMIT 2"
    }.each do |why, sql|
      it "is refused when #{why}" do
        expect(rewritten(sql)).to eq([])
      end
    end
  end

  # Task 20261003-35: the answers a Catalog keeps are keyed by everything
  # that decides them, so one Catalog asked about a schema's function, then
  # another's of the name, gives each its own answer, in either order.
  describe "the catalog's kept answers" do
    let(:safe) { PgQuery.parse("SELECT public.shout(a.title) FROM public.assignments a").tree }
    let(:many) { PgQuery.parse("SELECT elsewhere.shout(a.title) FROM public.assignments a").tree }

    it "tell a function of one schema from that of the same name in another, asked in either order" do
      expect([catalog.row_wise?([safe]), catalog.row_wise?([many])]).to eq([true, false])
      fresh = Quaack::Enclave::RewriteRules::Catalog.new(conn)
      expect([fresh.row_wise?([many]), fresh.row_wise?([safe])]).to eq([false, true])
    end

    it "tell a function from an operator of the same name" do
      conn.exec("CREATE FUNCTION public.\"###\"(text) RETURNS text IMMUTABLE LANGUAGE sql AS 'SELECT $1'")
      function = PgQuery.parse('SELECT "###"(a.title) FROM public.assignments a').tree
      operator = PgQuery.parse("SELECT a.id ### 2 FROM public.assignments a").tree

      expect([catalog.row_wise?([function]), catalog.row_wise?([operator])]).to eq([true, false])
    end

    it "tell a table's keys from those of the same name in another schema" do
      conn.exec("CREATE TABLE elsewhere.assignments (id int, title text)")

      expect([catalog.keys("public", "assignments").size, catalog.keys("elsewhere", "assignments")]).to eq([4, []])
    end
  end

  describe "a nondeterministic collation" do
    before do
      conn.exec(<<~SQL)
        CREATE COLLATION public.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
        CREATE TABLE public.names (name text COLLATE public.ci NOT NULL, note text);
        CREATE TABLE public.nested (name text COLLATE public.ci NOT NULL, note text);
        CREATE UNIQUE INDEX names_c ON public.names (name COLLATE "C");
        CREATE UNIQUE INDEX nested_ci ON public.nested (name);
        INSERT INTO public.names VALUES ('Ann', 'x'), ('ann', 'y');
        INSERT INTO public.nested VALUES ('Ann', 'x');
      SQL
    end

    it "refuses a key whose unique index compares differently, where DISTINCT folds two rows the index lets in" do
      sql = "SELECT DISTINCT n.name FROM public.names n JOIN public.submissions s ON s.state = n.note"

      expect(rewritten(sql)).to eq([])
      conn.exec("INSERT INTO public.submissions VALUES (1000, 1, 'x'), (1001, 1, 'y')")
      expect(rows(sql).size).to eq(1)
    end

    it "takes a key whose unique index compares the same way" do
      sql = "SELECT DISTINCT n.name FROM public.nested n JOIN public.submissions s ON s.state = n.note"

      expect(rewritten(sql).size).to eq(1)
    end
  end

  # Task 20261002-4: pairs' key is (x, y), and pair 1 has three submissions.
  describe "with a key of several columns" do
    pairs = "FROM public.pairs p JOIN public.submissions s ON s.a_id = p.x"

    it "takes it when the select list holds every column of it, and states each not null" do
      sql = "SELECT DISTINCT p.y, p.x #{pairs}"

      expect(rule.rewrites(PgQuery.parse(sql), catalog).map(&:assumptions)).to eq(
        [[{ "kind" => "unique", "table" => "public.pairs", "columns" => %w[x y] },
          { "kind" => "not_null", "table" => "public.pairs", "column" => "x" },
          { "kind" => "not_null", "table" => "public.pairs", "column" => "y" }]]
      )
      expect(same_rows(sql, rewritten(sql))).to eq([%w[1 1], %w[2 1]])
    end

    it "takes a star whose table has no key of one column" do
      sql = "SELECT DISTINCT p.* #{pairs}"

      expect(rewritten(sql)).to eq(
        ["SELECT p.* FROM public.pairs p WHERE EXISTS (SELECT 1 FROM public.submissions s WHERE s.a_id = p.x)"]
      )
      expect(same_rows(sql, rewritten(sql))).to eq([%w[1 1], %w[1 2]])
    end

    it "prefers a key of fewer columns, even one later in the select list or made later" do
      conn.exec(<<~SQL)
        CREATE TABLE public.trios (x int NOT NULL, y int NOT NULL, z int NOT NULL);
        CREATE UNIQUE INDEX ON public.trios (x, y);
        CREATE UNIQUE INDEX ON public.trios (z);
      SQL
      sql = "SELECT DISTINCT t.x, t.y, t.z FROM public.trios t JOIN public.submissions s ON s.a_id = t.x"

      expect(rule.rewrites(PgQuery.parse(sql), catalog).map(&:assumptions)).to eq(
        [[{ "kind" => "unique", "table" => "public.trios", "columns" => ["z"] },
          { "kind" => "not_null", "table" => "public.trios", "column" => "z" }]]
      )
    end

    it "takes a LIMIT when the ORDER BY holds every column of it" do
      sql = "SELECT DISTINCT p.x, p.y #{pairs} ORDER BY p.x, p.y DESC LIMIT 1"

      expect(same_ordered_rows(sql, rewritten(sql))).to eq([%w[1 2]])
    end
  end

  it "reads a table's keys once, however many columns its star stands for" do
    conn.exec("CREATE TABLE public.narrow (a int, b int)")
    conn.exec("CREATE TABLE public.wide (a int, b int, c int, d int, e int, f int, g int, h int)")
    reads = %w[narrow wide].map do |table|
      count = 0
      allow(conn).to(receive(:exec_params).and_wrap_original { |original, *args| (count += 1) && original.call(*args) })
      sql = "SELECT DISTINCT t.* FROM public.#{table} t JOIN public.submissions s ON s.a_id = t.a"
      expect(rule.rewrites(PgQuery.parse(sql), Quaack::Enclave::RewriteRules::Catalog.new(conn))).to eq([])
      count
    end

    expect(reads.first).to eq(reads.last)
  end

  # Each fires, and is the twin of a refusal below.
  {
    "a function of the kept table" => ["a.id, lower(a.title)", ""],
    "an expression of the key beside the key" => ["a.id + 0, a.id", ""],
    "a COLLATE" => [%(a.id, a.title COLLATE "C"), ""],
    "a cast" => ["a.id, a.ctx::text", ""],
    "a constant" => ["a.id, 1", ""],
    "an operator that returns one row" => ["a.id, a.id + 2", ""],
    "a stable function" => ["a.id, a.title || now()::date::text", ""],
    "a function named in its schema, when another schema has a set-returning one of the name" =>
      ["a.id, public.shout(a.title)", ""],
    "an unqualified column of the kept table alone" => ["a.id, title", ""],
    "an unqualified key" => ["slug, a.title", ""],
    "an unqualified column of the kept table, in an expression" => ["a.id, upper(title)", ""],
    "an output name in the ORDER BY" => ["a.id AS x, a.title", "ORDER BY x"],
    "an expression in the ORDER BY that's in the select list" =>
      ["a.id, lower(a.title)", "ORDER BY lower(a.title) DESC, a.id"],
    "an expression in the ORDER BY with the key, and a LIMIT" =>
      ["a.id + 0, a.id", "ORDER BY a.id + 0, a.id LIMIT 2 OFFSET 1"],
    "an output name in the ORDER BY with the key by name, and a LIMIT" =>
      ["a.title AS slug, a.slug AS s2", "ORDER BY slug, a.slug LIMIT 2"]
  }.each do |what, (list, order)|
    it "takes #{what} in the select list, and the rows are the same" do
      sql = "SELECT DISTINCT #{list} FROM public.assignments a JOIN public.submissions s ON s.a_id = a.id " \
            "WHERE a.ctx = 10 AND s.state = 'done' #{order}".strip

      rewrites = rewritten(sql)

      expect(rewrites.size).to eq(1)
      expect(rewrites.first).to start_with("SELECT #{list} FROM public.assignments a WHERE ")
      expect(rewrites.first).to end_with(order)
      if order.empty?
        expect(same_rows(sql, rewrites).size).to be > 1
      else
        expect(same_ordered_rows(sql, rewrites).size).to be > 1
      end
    end
  end

  it "resolves an unqualified column in a condition to its one table, and moves it with that table" do
    sql = "SELECT DISTINCT a.id FROM public.assignments a JOIN public.submissions s ON a_id = a.id " \
          "WHERE ctx = 10 AND state = 'done'"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT a.id FROM public.assignments a WHERE ctx = 10 AND " \
       "EXISTS (SELECT 1 FROM public.submissions s WHERE a_id = a.id AND state = 'done')"]
    )
    expect(same_rows(sql, rewrites)).to eq([["1"], ["2"], ["5"], ["6"]])
  end

  # The hand-tuned Canvas query of 20261002-16, as Rails writes it.
  describe "on Canvas's roster query" do
    # Users 1, 2, 4, 5, 6, and 8 are in course 7; 1 has three enrollments
    # there and 2 has two, so the join gives them more than once. 3 is
    # only in course 9, and 7 has none. 4 and 5 share a sortable name, and
    # 6 has none. Under the numeric collation, a2 sorts before a10.
    before do
      conn.exec(<<~SQL)
        CREATE COLLATION public."und-u-kn-true" (provider = icu, locale = 'und-u-kn-true');
        CREATE TABLE public.users (id bigint PRIMARY KEY, name text, sortable_name text, workflow_state text);
        CREATE TABLE public.enrollments (id bigint PRIMARY KEY, user_id bigint, course_id bigint, type text,
                                         workflow_state text);
        INSERT INTO public.users VALUES
          (1, 'A Ten', 'a10', 'registered'), (2, 'A Two', 'a2', 'registered'), (3, 'B', 'b', 'registered'),
          (4, 'C One', 'c', 'registered'), (5, 'C Two', 'c', 'registered'), (6, 'Nameless', NULL, 'registered'),
          (7, 'D', 'd', 'registered'), (8, 'E', 'E', 'pre_registered');
        INSERT INTO public.enrollments VALUES
          (1, 1, 7, 'StudentEnrollment', 'active'), (2, 1, 7, 'TeacherEnrollment', 'active'),
          (3, 1, 7, 'StudentEnrollment', 'invited'), (4, 2, 7, 'StudentEnrollment', 'active'),
          (5, 2, 7, 'StudentEnrollment', 'active'), (6, 3, 9, 'StudentEnrollment', 'active'),
          (7, 4, 7, 'StudentEnrollment', 'active'), (8, 5, 7, 'StudentEnrollment', 'active'),
          (9, 6, 7, 'StudentEnrollment', 'active'), (10, 8, 7, 'StudentEnrollment', 'active'),
          (11, NULL, 7, 'StudentEnrollment', 'active');
      SQL
    end

    let(:sql) do
      qualified(<<~SQL.tr("\n", " ").strip)
        SELECT DISTINCT users.*, sortable_name COLLATE public."und-u-kn-true"
        FROM users INNER JOIN enrollments ON users.id = enrollments.user_id
        WHERE enrollments.course_id = $1 AND enrollments.workflow_state <> 'deleted'
          AND enrollments.type IN ('StudentEnrollment', 'TeacherEnrollment')
        ORDER BY sortable_name COLLATE public."und-u-kn-true" ASC, users.id ASC LIMIT $2 OFFSET $3
      SQL
    end

    it "keeps users, moves enrollments into an EXISTS, and carries the ORDER BY, LIMIT, and OFFSET over" do
      expect(rewritten(sql)).to eq(
        ["SELECT users.*, sortable_name COLLATE public.\"und-u-kn-true\" FROM public.users WHERE " \
         "EXISTS (SELECT 1 FROM public.enrollments WHERE users.id = enrollments.user_id AND " \
         "enrollments.course_id = $1 AND enrollments.workflow_state <> 'deleted' AND " \
         "enrollments.type IN ('StudentEnrollment', 'TeacherEnrollment')) " \
         "ORDER BY sortable_name COLLATE public.\"und-u-kn-true\" ASC, users.id ASC LIMIT $2 OFFSET $3"]
      )
      expect(rule.rewrites(PgQuery.parse(sql), catalog).first.assumptions).to eq(
        [{ "kind" => "unique", "table" => "public.users", "columns" => ["id"] },
         { "kind" => "not_null", "table" => "public.users", "column" => "id" }]
      )
    end

    it "gives the same rows in the same order on every page" do
      rewrites = rewritten(sql)

      expect(same_ordered_rows(sql, rewrites, [7, 20, 0]).map(&:first)).to eq(%w[2 1 4 5 8 6])
      (0..6).each { |offset| same_ordered_rows(sql, rewrites, [7, 2, offset]) }
    end

    it "refuses when the select list reads a column of enrollments, qualified or not" do
      reads_enrollment = sql.sub("SELECT DISTINCT users.*,", "SELECT DISTINCT users.*, enrollments.type,")
      unqualified = sql.sub("SELECT DISTINCT users.*,", "SELECT DISTINCT users.*, course_id,")

      expect(rewritten(sql).size).to eq(1)
      expect(rewritten(reads_enrollment)).to eq([])
      expect(rewritten(unqualified)).to eq([])
    end

    it "refuses an unqualified column both tables have" do
      ambiguous = sql.sub(%(sortable_name COLLATE public."und-u-kn-true" FROM),
                          %(sortable_name COLLATE public."und-u-kn-true", workflow_state FROM))

      expect(rewritten(ambiguous)).to eq([])
    end
  end

  it "doesn't fire on its own output, so the generator gives the one rewrite" do
    generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(fires), catalog, rules: [rule])

    expect(generated.rewrites.map(&:sql)).to eq(rewritten(fires))
    expect(generated.rewrites.map { |rewrite| rewrite.rules.map(&:name) }).to eq([%w[distinct_join_to_exists]])
  end

  # Each is the query that fires, changed in one way that makes it unsafe or
  # unproven.
  from = "FROM public.assignments a JOIN public.submissions s ON s.a_id = a.id"
  where = "WHERE a.ctx = 10 AND s.state = 'done'"
  {
    "there's no DISTINCT" => "SELECT a.id, a.title #{from} #{where}",
    "it's DISTINCT ON" => "SELECT DISTINCT ON (a.id) a.id, a.title #{from} #{where}",
    "the select list has no key" => "SELECT DISTINCT a.title #{from} #{where}",
    "the only unique column selected is nullable" => "SELECT DISTINCT a.code, a.title #{from} #{where}",
    "the only unique column selected is NULLS NOT DISTINCT, but nullable" =>
      "SELECT DISTINCT a.tag, a.title #{from} #{where}",
    "the only not-null column selected isn't unique" => "SELECT DISTINCT a.loose, a.title #{from} #{where}",
    "the select list holds only part of a key of several columns" =>
      "SELECT DISTINCT p.x FROM public.pairs p JOIN public.submissions s ON s.a_id = p.x",
    "it has a LIMIT and the ORDER BY holds only part of a key of several columns" =>
      "SELECT DISTINCT p.x, p.y FROM public.pairs p JOIN public.submissions s ON s.a_id = p.x ORDER BY p.x LIMIT 1",
    "an assumption can't name the kept table" =>
      %(SELECT DISTINCT a.id, a.title FROM public."my a" a JOIN public.submissions s ON s.a_id = a.id),
    "the select list reads another table too" => "SELECT DISTINCT a.id, s.state #{from} #{where}",
    "the select list reads the other table's key too" => "SELECT DISTINCT s.id, a.title #{from} #{where}",
    "the select list has another table's star" => "SELECT DISTINCT a.id, s.* #{from} #{where}",
    "the select list is a bare star" => "SELECT DISTINCT * #{from} #{where}",
    "the select list has an expression of the key and not the key" =>
      "SELECT DISTINCT a.id + 0, a.title #{from} #{where}",
    "the select list has an expression of another table" =>
      "SELECT DISTINCT a.id, lower(s.state) #{from} #{where}",
    "the select list has an expression of both tables" =>
      "SELECT DISTINCT a.id, a.title || s.state #{from} #{where}",
    "the select list has a set-returning function" =>
      "SELECT DISTINCT a.id, unnest(ARRAY[a.title, a.title]) #{from} #{where}",
    "the select list has a set-returning function of no column" =>
      "SELECT DISTINCT a.id, generate_series(1, 2) #{from} #{where}",
    "the select list has a set-returning operator" => "SELECT DISTINCT a.id, a.id ### 2 #{from} #{where}",
    "the select list calls a set-returning function in attribute notation" =>
      "SELECT DISTINCT a.id, a.both #{from} #{where}",
    "the select list calls a function some schema has a set-returning one of, without naming the schema" =>
      "SELECT DISTINCT a.id, shout(a.title) #{from} #{where}",
    "the select list has a window function" => "SELECT DISTINCT a.id, count(*) OVER () #{from} #{where}",
    "the select list has a window function of the kept table" =>
      "SELECT DISTINCT a.id, row_number() OVER (ORDER BY a.id) #{from} #{where}",
    "the select list has a volatile function" => "SELECT DISTINCT a.id, random() #{from} #{where}",
    "the select list has a volatile function of the kept table" =>
      "SELECT DISTINCT a.id, a.title || random()::text #{from} #{where}",
    "the select list has only constants" => "SELECT DISTINCT 1 #{from} #{where}",
    "the select list has a subquery" => "SELECT DISTINCT a.id, (SELECT 1) #{from} #{where}",
    "the select list has an unqualified column of another table" =>
      "SELECT DISTINCT a.id, state #{from} #{where}",
    "the select list has an unqualified column of both tables" => "SELECT DISTINCT id, a.title #{from} #{where}",
    "the select list has an unqualified column of no table" =>
      "SELECT DISTINCT a.id, missing #{from} #{where}",
    "the select list has an unqualified column only a removed table has, in an expression" =>
      "SELECT DISTINCT a.id, upper(state) #{from} #{where}",
    "the select list has a table's whole row by its bare name" => "SELECT DISTINCT a.id, a #{from} #{where}",
    "the select list has a three-part column" => "SELECT DISTINCT a.id, public.a.title #{from} #{where}",
    "a condition has an unqualified column of both tables" => "SELECT DISTINCT a.id, a.title #{from} WHERE id = 1",
    "a condition has an unqualified column of no table" =>
      "SELECT DISTINCT a.id, a.title #{from} WHERE missing = 1",
    "a condition has a three-part column" =>
      "SELECT DISTINCT a.id, a.title #{from} WHERE public.s.state = 'done'",
    "a condition has a whole-row reference" => "SELECT DISTINCT a.id, a.title #{from} WHERE s.* IS NOT NULL",
    "a condition has a subquery" =>
      "SELECT DISTINCT a.id, a.title #{from} WHERE s.id IN (SELECT 101)",
    "a condition's subquery reads a removed table by name" =>
      "#{fires} AND a.id IN (SELECT c.id FROM public.comments c WHERE c.s_id = s.id)",
    "a condition's subquery reads a column only a removed table has, unqualified" =>
      "#{fires} AND EXISTS (SELECT 1 FROM public.comments c WHERE c.s_id = a_id)",
    "a condition's subquery reads a removed table from a nested subquery" =>
      "#{fires} AND EXISTS (SELECT 1 FROM public.comments c WHERE c.id = a.id AND " \
      "EXISTS (SELECT 1 FROM public.comments d WHERE d.s_id = s.id))",
    "a condition's subquery reads a removed table by a name its own table's alias hides" =>
      "SELECT DISTINCT a.id FROM public.assignments a JOIN public.submissions ON submissions.a_id = a.id " \
      "WHERE EXISTS (SELECT 1 FROM public.submissions x WHERE x.id = submissions.id)",
    "a condition's subquery reads a removed table's whole row" =>
      "#{fires} AND EXISTS (SELECT s.* FROM public.comments c)",
    "a condition's subquery reads the kept table's whole row" =>
      "#{fires} AND EXISTS (SELECT a.* FROM public.comments c)",
    "a condition's subquery has a column no table has" =>
      "#{fires} AND EXISTS (SELECT 1 FROM public.comments c WHERE missing = 1)",
    "a condition's subquery has a column two of its tables have" =>
      "#{fires} AND EXISTS (SELECT 1 FROM public.comments c, public.submissions x WHERE c.s_id = x.id AND id = 1)",
    "a condition's subquery has a three-part column" =>
      "#{fires} AND EXISTS (SELECT 1 FROM public.comments c WHERE public.c.id = a.id)",
    "a condition's subquery joins its tables" =>
      "#{fires} AND EXISTS (SELECT 1 FROM public.comments c JOIN public.submissions x ON x.id = c.s_id " \
      "WHERE x.a_id = a.id)",
    "a condition's subquery reads a subquery" =>
      "#{fires} AND EXISTS (SELECT 1 FROM (SELECT * FROM public.comments) c WHERE c.id = a.id)",
    "a condition's subquery reads a table that isn't schema-qualified" =>
      "#{fires} AND EXISTS (SELECT 1 FROM comments c WHERE c.id = a.id)",
    "a condition's subquery has a WITH" =>
      "#{fires} AND EXISTS (WITH w AS (SELECT 1) SELECT 1 FROM public.comments c WHERE c.id = a.id)",
    "a condition's subquery is a UNION" => "#{fires} AND a.id IN (SELECT 1 UNION SELECT 2)",
    "a condition's subquery reads, by no column, a table that isn't schema-qualified" =>
      "#{fires} AND EXISTS (SELECT 1 FROM comments c)",
    "a condition's subquery calls a volatile function of its own table's row, written as a column" =>
      "#{fires} AND EXISTS (SELECT 1 FROM public.comments c WHERE c.stamp < 2)",
    "a condition's subquery reads a table with ONLY" =>
      "#{fires} AND EXISTS (SELECT 1 FROM ONLY public.comments c WHERE c.id = a.id)",
    "a condition's subquery's alias renames its table's columns" =>
      "#{fires} AND EXISTS (SELECT 1 FROM public.comments c (cid) WHERE c.cid = a.id)",
    "a condition's subquery calls a volatile function" =>
      "#{fires} AND a.id IN (SELECT x.a_id FROM public.submissions x WHERE random() < 2)",
    "a subquery's test reads a removed table" =>
      "#{fires} AND s.id IN (SELECT x.id FROM public.submissions x WHERE x.a_id = a.id)",
    "the ORDER BY has a subquery" => "#{fires} ORDER BY a.title, (SELECT 1)",
    "the LIMIT has a subquery" => "#{fires} ORDER BY a.id LIMIT (SELECT 1)",
    "the OFFSET has a subquery" => "#{fires} ORDER BY a.id LIMIT 5 OFFSET (SELECT 0)",
    "a join condition has a subquery" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a JOIN public.submissions s " \
      "ON s.a_id = a.id AND s.id IN (SELECT 101)",
    "the ORDER BY reads another table" => "SELECT DISTINCT a.id, a.title #{from} #{where} ORDER BY s.id",
    "the ORDER BY has a volatile function" =>
      "SELECT DISTINCT a.id, a.title #{from} #{where} ORDER BY random()",
    "it has a LIMIT and the key is sorted only in an expression" =>
      "SELECT DISTINCT a.id + 0, a.id #{from} #{where} ORDER BY a.id + 0 LIMIT 2",
    "it has a LIMIT and the key is sorted only by its unqualified name" =>
      "SELECT DISTINCT a.title AS slug, a.slug AS s2 #{from} #{where} ORDER BY slug LIMIT 2",
    "it has a LIMIT and no ORDER BY" => "#{fires} LIMIT 2",
    "it has an OFFSET and no ORDER BY" => "#{fires} OFFSET 2",
    "it has a LIMIT and an ORDER BY with no key" => "#{fires} ORDER BY a.title LIMIT 2",
    "it has a LIMIT and an ORDER BY by position" => "#{fires} ORDER BY 1 LIMIT 2",
    "it has GROUP BY" => "#{fires} GROUP BY a.id, a.title",
    "it has HAVING" => "#{fires} HAVING true",
    "it has a WINDOW clause" => "#{fires} WINDOW w AS ()",
    "it locks rows" => "#{fires} FOR UPDATE",
    "it has a WITH" => "WITH w AS (SELECT 1) #{fires}",
    "it's a UNION" => "#{fires} UNION SELECT s.id, s.state FROM public.submissions s",
    "it reads one table" => "SELECT DISTINCT a.id, a.title FROM public.assignments a WHERE a.ctx = 10",
    "the join is a LEFT JOIN" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a LEFT JOIN public.submissions s ON s.a_id = a.id",
    "the join is a RIGHT JOIN" =>
      "SELECT DISTINCT a.id, a.title FROM public.submissions s RIGHT JOIN public.assignments a ON s.a_id = a.id",
    "the join is a FULL JOIN" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a FULL JOIN public.submissions s ON s.a_id = a.id",
    "the join is NATURAL" => "SELECT DISTINCT a.id FROM public.assignments a NATURAL JOIN public.submissions s",
    "the join has USING" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a JOIN public.submissions s USING (id)",
    "the join has an alias" =>
      "SELECT DISTINCT a.id, a.title FROM (public.assignments a JOIN public.submissions s ON s.a_id = a.id) a",
    "the kept name is a subquery's" =>
      "SELECT DISTINCT a.id, a.title FROM (SELECT * FROM public.assignments) a JOIN public.submissions s " \
      "ON s.a_id = a.id",
    "another FROM item is a subquery" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a JOIN (SELECT * FROM public.submissions) s " \
      "ON s.a_id = a.id",
    "another FROM item is a function" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a, generate_series(1, 2) g WHERE g.g = a.id",
    "the kept table is read with ONLY" =>
      "SELECT DISTINCT a.id, a.title FROM ONLY public.assignments a JOIN public.submissions s ON s.a_id = a.id",
    "another table is read with ONLY" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a JOIN ONLY public.submissions s ON s.a_id = a.id",
    "the kept table's alias renames columns" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a (id, title) JOIN public.submissions s ON s.a_id = a.id",
    "another table's alias renames columns" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a JOIN public.submissions s (id, a_id) ON s.a_id = a.id",
    "the kept table is a CTE" =>
      "WITH a AS (SELECT * FROM public.assignments) SELECT DISTINCT a.id, a.title FROM a " \
      "JOIN public.submissions s ON s.a_id = a.id",
    "another table isn't schema-qualified" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a JOIN submissions s ON s.a_id = a.id",
    "two FROM items have the same name" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a JOIN public.submissions a ON a.a_id = a.id"
  }.each do |why, sql|
    it "doesn't fire when #{why}" do
      expect(rewritten(fires).size).to eq(1)
      expect(rewritten(sql)).to eq([])
    end
  end

  # What the rule would write for each, written by hand: the kept table
  # with an EXISTS on the other.
  describe "what it refuses would be wrong" do
    def exists(list, where = "") = <<~SQL
      SELECT #{list} FROM public.assignments a WHERE a.ctx = 10 #{where}
      AND EXISTS (SELECT 1 FROM public.submissions s WHERE s.a_id = a.id AND s.state = 'done')
    SQL

    def distinct(list)
      "SELECT DISTINCT #{list} FROM public.assignments a JOIN public.submissions s ON s.a_id = a.id " \
        "WHERE a.ctx = 10 AND s.state = 'done'"
    end

    {
      "with no key selected" => "a.title",
      "with a nullable unique column" => "a.code, a.title",
      "with a not-null column that isn't unique" => "a.loose, a.title"
    }.each do |which, list|
      it "#{which}: DISTINCT merges the two assignments that differ only outside the select list" do
        expect(rows(distinct(list)).size).to eq(3)
        expect(rows(exists(list)).size).to eq(4)
      end
    end

    it "with a set-returning function: DISTINCT merges the rows one assignment gives" do
      list = "a.id, unnest(ARRAY[a.title, a.title])"

      expect(rows(distinct(list)).size).to eq(4)
      expect(rows(exists(list)).size).to eq(8)
    end

    it "with a set-returning function in attribute notation: likewise" do
      expect(rows(distinct("a.id, a.both")).size).to eq(4)
      expect(rows(exists("a.id, a.both")).size).to eq(8)
    end

    it "with a window function: it counts the join's rows, not the assignments" do
      list = "a.id, count(*) OVER ()"

      expect(rows(distinct(list)).map(&:last).uniq).to eq(["6"])
      expect(rows(exists(list)).map(&:last).uniq).to eq(["4"])
    end

    it "with a LEFT JOIN: an assignment with no submission is kept" do
      left = "SELECT DISTINCT a.id FROM public.assignments a LEFT JOIN public.submissions s ON s.a_id = a.id"
      exists = "SELECT a.id FROM public.assignments a WHERE EXISTS " \
               "(SELECT 1 FROM public.submissions s WHERE s.a_id = a.id)"

      expect(rows(left)).to include(["3"])
      expect(rows(exists)).not_to include(["3"])
    end
  end

  describe "the catalog's columns" do
    it "are the table's, in order, without dropped or system columns" do
      conn.exec("ALTER TABLE public.comments DROP COLUMN s_id")

      expect(catalog.column_names("public", "comments")).to eq(%w[id body])
      expect(catalog.column_names("public", "my a")).to eq(%w[id title])
    end

    it "are those of the table in the schema named, not of another schema's table of the same name" do
      conn.exec("CREATE SCHEMA other; CREATE TABLE other.comments (ref int, note text, at date)")

      expect(catalog.column_names("public", "comments")).to eq(%w[id s_id body])
      expect(catalog.column_names("other", "comments")).to eq(%w[ref note at])
    end

    it "are none for a table that doesn't exist" do
      expect(catalog.column_names("public", "missing")).to eq([])
    end
  end
end
