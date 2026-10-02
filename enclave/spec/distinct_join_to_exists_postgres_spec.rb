# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/relation_qualifier"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# DESIGN.md 6c's distinct_join_to_exists, on a real server: what it writes,
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

  # As step 1 qualifies it.
  def qualified(sql) = Quaack::Enclave::RelationQualifier.qualify(sql, nil, conn).sql

  fires = "SELECT DISTINCT a.id, a.title FROM public.assignments a JOIN public.submissions s ON s.a_id = a.id " \
          "WHERE a.ctx = 10 AND s.state = 'done'"
  let(:fires) { fires }

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["distinct_join_to_exists",
       "A SELECT DISTINCT of one table's columns over a join, with a unique, not-null key of that table among " \
       "them, becomes that table alone with an EXISTS on the other tables, and no DISTINCT."]
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

  it "states the key unique and not null, in 6b's vocabulary" do
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

  it "leaves an EXISTS with no condition for a join that has none" do
    sql = "SELECT DISTINCT p.x, p.y, p.x FROM public.pairs p CROSS JOIN public.comments c"
    keyed = "SELECT DISTINCT a.id FROM public.assignments a CROSS JOIN public.comments c WHERE a.ctx = 11"

    expect(rewritten(sql)).to eq([])
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
    "the key is of several columns" =>
      "SELECT DISTINCT p.x, p.y FROM public.pairs p JOIN public.submissions s ON s.a_id = p.x",
    "a star's table has only a key of several columns" =>
      "SELECT DISTINCT p.* FROM public.pairs p JOIN public.submissions s ON s.a_id = p.x",
    "an assumption can't name the kept table" =>
      %(SELECT DISTINCT a.id, a.title FROM public."my a" a JOIN public.submissions s ON s.a_id = a.id),
    "the select list reads another table too" => "SELECT DISTINCT a.id, s.state #{from} #{where}",
    "the select list reads the other table's key too" => "SELECT DISTINCT s.id, a.title #{from} #{where}",
    "the select list has another table's star" => "SELECT DISTINCT a.id, s.* #{from} #{where}",
    "the select list is a bare star" => "SELECT DISTINCT * #{from} #{where}",
    "the select list has an expression" => "SELECT DISTINCT a.id, lower(a.title) #{from} #{where}",
    "the select list has an expression of the key" => "SELECT DISTINCT a.id + 0, a.id #{from} #{where}",
    "the select list has a set-returning function" =>
      "SELECT DISTINCT a.id, unnest(ARRAY[a.title, a.title]) #{from} #{where}",
    "the select list has a window function" => "SELECT DISTINCT a.id, count(*) OVER () #{from} #{where}",
    "the select list has a constant" => "SELECT DISTINCT a.id, 1 #{from} #{where}",
    "the select list has a subquery" => "SELECT DISTINCT a.id, (SELECT 1) #{from} #{where}",
    "the select list has an unqualified column" => "SELECT DISTINCT a.id, title #{from} #{where}",
    "the select list has a three-part column" => "SELECT DISTINCT a.id, public.a.title #{from} #{where}",
    "a condition has an unqualified column" => "SELECT DISTINCT a.id, a.title #{from} WHERE ctx = 10",
    "a condition has a three-part column" =>
      "SELECT DISTINCT a.id, a.title #{from} WHERE public.s.state = 'done'",
    "a condition has a whole-row reference" => "SELECT DISTINCT a.id, a.title #{from} WHERE s.* IS NOT NULL",
    "a condition has a subquery" =>
      "SELECT DISTINCT a.id, a.title #{from} WHERE s.id IN (SELECT 101)",
    "a condition on the kept table has a subquery" =>
      "SELECT DISTINCT a.id, a.title #{from} WHERE a.id IN (SELECT 1)",
    "a join condition has a subquery" =>
      "SELECT DISTINCT a.id, a.title FROM public.assignments a JOIN public.submissions s " \
      "ON s.a_id = a.id AND s.id IN (SELECT 101)",
    "the ORDER BY has an output name" => "SELECT DISTINCT a.id AS x, a.title #{from} #{where} ORDER BY x",
    "the ORDER BY has an expression" => "SELECT DISTINCT a.id, a.title #{from} #{where} ORDER BY a.id + 0",
    "the ORDER BY reads another table" => "SELECT DISTINCT a.id, a.title #{from} #{where} ORDER BY s.id",
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

      expect(catalog.columns("public", "comments")).to eq(%w[id body])
      expect(catalog.columns("public", "my a")).to eq(%w[id title])
    end

    it "are those of the table in the schema named, not of another schema's table of the same name" do
      conn.exec("CREATE SCHEMA other; CREATE TABLE other.comments (ref int, note text, at date)")

      expect(catalog.columns("public", "comments")).to eq(%w[id s_id body])
      expect(catalog.columns("other", "comments")).to eq(%w[ref note at])
    end

    it "are none for a table that doesn't exist" do
      expect(catalog.columns("public", "missing")).to eq([])
    end
  end
end
