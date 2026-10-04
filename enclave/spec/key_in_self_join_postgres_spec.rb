# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/relation_qualifier"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules's key_in_self_join, on a real server: what it writes, that
# its output returns the rows its input does on data that would show a
# wrong transformation, and that it only fires when the catalog proves the
# key unique and not null and the shape is one it can relocate.
RSpec.describe Quaack::Enclave::RewriteRules::KeyInSelfJoin do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  after do
    conn.close
    production.drop
  end

  # The rule's rewrites of sql, each as SQL.
  def rewritten(sql)
    rule.rewrites(PgQuery.parse(sql), catalog).map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  def rows(sql, params = []) = conn.exec_params(sql, params).values.sort_by(&:to_s)

  # The original's rows, once every rewrite has been checked to return the same.
  def same_rows(sql, rewrites, params = [])
    expected = rows(sql, params)
    expect(rewrites).not_to be_empty
    rewrites.each { expect(rows(it, params)).to eq(expected), "#{it} returns other rows" }
    expected
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["key_in_self_join",
       "An IN subquery that reads the outer table again by a unique, not-null key becomes that table's own " \
       "predicates, and an EXISTS on what's left of the subquery."]
    )
  end

  context "with a table, a unique not-null key, and a table that joins to it" do
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.t (id int PRIMARY KEY, x int, code text UNIQUE, tag text, loose int NOT NULL);
        CREATE UNIQUE INDEX t_tag ON public.t (tag) NULLS NOT DISTINCT;
        CREATE TABLE public.u (id int PRIMARY KEY, t_id int, y int);
        CREATE TABLE public."my t" (id int PRIMARY KEY, x int);
        CREATE SCHEMA other;
        CREATE TABLE other.t (id int PRIMARY KEY, x int);
        INSERT INTO public.t VALUES (1, 1, 'a', 'a', 1), (2, 2, 'b', 'b', 1), (3, NULL, 'c', NULL, 3), (4, 1, NULL, 'd', 4);
        INSERT INTO public.u VALUES (1, 1, 1), (2, 1, 1), (3, 2, 1), (4, 4, 2), (5, NULL, 1);
        INSERT INTO public."my t" VALUES (1, 1);
        INSERT INTO other.t VALUES (1, 1);
      SQL
    end

    let(:fires) { "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)" }

    it "leaves only the predicates, moved to the outer table, when the subquery reads nothing else" do
      rewrites = rewritten(fires)

      expect(rewrites).to eq(["SELECT t.id FROM public.t WHERE t.x = 1"])
      expect(same_rows(fires, rewrites)).to eq([["1"], ["4"]])
    end

    it "states the key unique and not null, in assumption-check's vocabulary" do
      expect(rule.rewrites(PgQuery.parse(fires), catalog).map(&:assumptions)).to eq(
        [[{ "kind" => "unique", "table" => "public.t", "columns" => ["id"] },
          { "kind" => "not_null", "table" => "public.t", "column" => "id" }]]
      )
    end

    it "doesn't change the parse it was given" do
      parse = PgQuery.parse(fires)
      before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

      rule.rewrites(parse, catalog)

      expect(parse.tree).to eq(before)
    end

    it "leaves true when the subquery has no predicate and reads nothing else" do
      sql = "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2)"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(["SELECT t.id FROM public.t WHERE true"])
      expect(same_rows(sql, rewrites).size).to eq(4)
    end

    it "leaves an EXISTS on the other tables, under fresh aliases, that duplicate join rows don't multiply" do
      sql = "SELECT o.id, o.x FROM public.t o WHERE o.loose < 4 AND o.id IN " \
            "(SELECT i.id FROM public.t i JOIN public.u ON u.t_id = i.id WHERE u.y = 1 AND i.x = 1) AND o.id > 0"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT o.id, o.x FROM public.t o WHERE o.loose < 4 AND o.x = 1 AND " \
         "EXISTS (SELECT 1 FROM public.u u_1 WHERE u_1.y = 1 AND u_1.t_id = o.id) AND o.id > 0"]
      )
      expect(same_rows(sql, rewrites)).to eq([%w[1 1]])
    end

    it "handles each UNION ALL arm on its own and joins them with OR, with a row both arms give kept once" do
      sql = "SELECT t.id FROM public.t WHERE t.id IN (SELECT a.id FROM public.t a WHERE a.x = 1 UNION ALL " \
            "SELECT b.id FROM public.t b, public.u WHERE u.t_id = b.id AND u.y = 1 AND b.loose = 1)"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT t.id FROM public.t WHERE t.x = 1 OR (t.loose = 1 AND " \
         "EXISTS (SELECT 1 FROM public.u u_1 WHERE u_1.t_id = t.id AND u_1.y = 1))"]
      )
      expect(same_rows(sql, rewrites)).to eq([["1"], ["2"], ["4"]])
    end

    it "takes several arms, a UNION, and DISTINCT, none of which changes what IN gives" do
      sql = "SELECT t.id FROM public.t WHERE t.id IN (SELECT DISTINCT a.id FROM public.t a WHERE a.x = 2 UNION " \
            "SELECT b.id FROM public.t b WHERE b.id = 3 UNION ALL " \
            "SELECT c.id FROM public.t c JOIN public.u ON u.t_id = c.id WHERE u.y = 2 UNION ALL " \
            "SELECT d.id FROM public.t d JOIN public.u ON u.t_id = d.id AND u.id = 9 WHERE u.y = 1)"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT t.id FROM public.t WHERE t.x = 2 OR t.id = 3 OR " \
         "EXISTS (SELECT 1 FROM public.u u_1 WHERE u_1.y = 2 AND u_1.t_id = t.id) OR " \
         "EXISTS (SELECT 1 FROM public.u u_2 WHERE u_2.y = 1 AND u_2.t_id = t.id AND u_2.id = 9)"]
      )
      expect(same_rows(sql, rewrites)).to eq([["2"], ["3"], ["4"]])
    end

    it "picks an alias no name in the query uses, so the EXISTS still reads the outer table" do
      sql = "SELECT u_1.id FROM public.t u_1 WHERE u_1.id IN " \
            "(SELECT t2.id FROM public.t t2 JOIN public.u ON u.t_id = t2.id WHERE u.y = 2)"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT u_1.id FROM public.t u_1 WHERE " \
         "EXISTS (SELECT 1 FROM public.u u_2 WHERE u_2.y = 2 AND u_2.t_id = u_1.id)"]
      )
      expect(same_rows(sql, rewrites)).to eq([["4"]])
    end

    it "keeps a second read of the same table in the subquery, apart from the outer one" do
      sql = "SELECT t.id FROM public.t WHERE t.id IN " \
            "(SELECT t.id FROM public.t JOIN public.t b ON b.x = t.x WHERE b.id <> t.id)"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT t.id FROM public.t WHERE EXISTS (SELECT 1 FROM public.t b_1 WHERE b_1.id <> t.id AND b_1.x = t.x)"]
      )
      expect(same_rows(sql, rewrites)).to eq([["1"], ["4"]])
    end

    it "fires when the outer table is on the kept side of an outer join" do
      sql = "SELECT t.id, u.id FROM public.t LEFT JOIN public.u ON u.t_id = t.id AND u.y = 2 " \
            "WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)"
      mirrored = "SELECT t.id, u.id FROM public.u RIGHT JOIN public.t ON u.t_id = t.id AND u.y = 2 " \
                 "WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)"

      expect(same_rows(sql, rewritten(sql))).to eq([["1", nil], %w[4 4]])
      expect(rewritten(mirrored).size).to eq(1)
    end

    it "gives one rewrite per matching IN, and the generator's second pass rewrites both" do
      sql = "SELECT t.id FROM public.t WHERE t.id IN (SELECT a.id FROM public.t a WHERE a.x = 1) " \
            "AND t.id IN (SELECT b.id FROM public.t b JOIN public.u ON u.t_id = b.id WHERE u.y = 1)"

      generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(sql), catalog)

      expect(rewritten(sql)).to eq(generated.rewrites.first(2).map(&:sql))
      expect(generated.rewrites.map(&:sql)).to eq(
        ["SELECT t.id FROM public.t WHERE t.x = 1 AND t.id IN " \
         "(SELECT b.id FROM public.t b JOIN public.u ON u.t_id = b.id WHERE u.y = 1)",
         "SELECT t.id FROM public.t WHERE t.id IN (SELECT a.id FROM public.t a WHERE a.x = 1) AND " \
         "EXISTS (SELECT 1 FROM public.u u_1 WHERE u_1.y = 1 AND u_1.t_id = t.id)",
         "SELECT t.id FROM public.t WHERE t.x = 1 AND " \
         "EXISTS (SELECT 1 FROM public.u u_1 WHERE u_1.y = 1 AND u_1.t_id = t.id)"]
      )
      expect(generated.rewrites.map { |rewrite| rewrite.rules.map(&:name) })
        .to eq([%w[key_in_self_join], %w[key_in_self_join], %w[key_in_self_join key_in_self_join]])
      expect(generated.duplicates).to eq(1)
      expect(same_rows(sql, generated.rewrites.map(&:sql))).to eq([["1"]])
    end

    # Each is the query that fires, changed in one way that makes it unsafe
    # or unproven.
    {
      "the key isn't unique" =>
        "SELECT t.id FROM public.t WHERE t.loose IN (SELECT t2.loose FROM public.t t2 WHERE t2.x = 1)",
      "the key is unique but nullable" =>
        "SELECT t.id FROM public.t WHERE t.code IN (SELECT t2.code FROM public.t t2 WHERE t2.x = 1)",
      "the key is unique with NULLS NOT DISTINCT, but nullable" =>
        "SELECT t.id FROM public.t WHERE t.tag IN (SELECT t2.tag FROM public.t t2 WHERE t2.x IS NULL)",
      "an assumption can't name the table" =>
        %(SELECT t.id FROM public."my t" t WHERE t.id IN (SELECT t2.id FROM public."my t" t2 WHERE t2.x = 1)),
      "it's NOT IN" => "SELECT t.id FROM public.t WHERE t.id NOT IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the IN is under an OR" =>
        "SELECT t.id FROM public.t WHERE t.x = 2 OR t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the IN is in the select list" =>
        "SELECT t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1) FROM public.t",
      "it's = ANY" => "SELECT t.id FROM public.t WHERE t.id = ANY (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "it's <> ALL" => "SELECT t.id FROM public.t WHERE t.id <> ALL (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "it's EXISTS already" => "SELECT t.id FROM public.t WHERE EXISTS (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the tested expression is a row" =>
        "SELECT t.id FROM public.t WHERE (t.id, t.x) IN (SELECT t2.id, t2.x FROM public.t t2 WHERE t2.x = 1)",
      "the tested column isn't qualified" =>
        "SELECT t.id FROM public.t WHERE id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the subquery gives another column" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.x FROM public.t t2 WHERE t2.x = 1)",
      "the subquery gives an expression" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id + 0 FROM public.t t2 WHERE t2.x = 1)",
      "the subquery gives an aggregate" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT max(t2.id) FROM public.t t2 WHERE t2.x = 1)",
      "the subquery gives another table's column" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT u.id FROM public.u JOIN public.t t2 ON t2.id = u.t_id)",
      "the subquery reads another schema's table of the same name" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM other.t t2 WHERE t2.x = 1)",
      "the subquery has GROUP BY" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1 GROUP BY t2.id)",
      "the subquery has HAVING" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1 HAVING true)",
      "the subquery has a WINDOW clause" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1 WINDOW w AS ())",
      "the subquery has ORDER BY" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1 ORDER BY t2.id)",
      "the subquery has LIMIT" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1 LIMIT 1)",
      "the subquery has OFFSET" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1 OFFSET 1)",
      "the subquery locks rows" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1 FOR UPDATE)",
      "the subquery has a WITH" =>
        "SELECT t.id FROM public.t WHERE t.id IN (WITH w AS (SELECT 1) SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the subquery has DISTINCT ON" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT DISTINCT ON (t2.x) t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the subquery has an outer join" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 LEFT JOIN public.u ON u.t_id = t2.id)",
      "the subquery has a NATURAL JOIN" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 NATURAL JOIN public.u)",
      "the subquery has JOIN USING" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 JOIN public.u USING (id))",
      "the subquery's join has an alias" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT t2.id FROM (public.t t2 JOIN public.u ON u.t_id = t2.id) t2 WHERE t2.x = 1)",
      "the subquery reads a subquery" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT t2.id FROM public.t t2 JOIN (SELECT u.t_id FROM public.u) s ON s.t_id = t2.id)",
      "the subquery reads the table with ONLY" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM ONLY public.t t2 WHERE t2.x = 1)",
      "the subquery's alias renames columns" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 (id, x) WHERE t2.x = 1)",
      "the subquery reads a CTE" =>
        "WITH w AS (SELECT u.t_id FROM public.u) SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT t2.id FROM public.t t2 JOIN w ON w.t_id = t2.id)",
      "the subquery's predicate has a subquery" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT t2.id FROM public.t t2 WHERE EXISTS (SELECT 1 FROM public.u t2 WHERE t2.y = 1))",
      "the subquery's join condition has a subquery" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT t2.id FROM public.t t2 JOIN public.u ON EXISTS (SELECT 1 FROM public.u u2 WHERE u2.t_id = t2.id))",
      "the subquery has an unqualified column" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE x = 1)",
      "the subquery has an unqualified column with a table's name" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT x.id FROM public.t x WHERE x = 1)",
      "the subquery refers to the outer query" =>
        "SELECT o.id FROM public.t o WHERE o.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = o.x)",
      "the subquery has a three-part column" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT t2.id FROM public.t t2 JOIN public.u ON public.u.t_id = t2.id)",
      "the subquery has a whole-row reference" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.* IS NOT NULL)",
      "one UNION ALL arm doesn't read the table by its key" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT t2.id FROM public.t t2 WHERE t2.x = 1 UNION ALL SELECT u.t_id FROM public.u)",
      "the arms are joined by INTERSECT" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT a.id FROM public.t a WHERE a.x = 1 INTERSECT SELECT b.id FROM public.t b WHERE b.id = 1)",
      "the arms are joined by EXCEPT" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT a.id FROM public.t a WHERE a.x = 1 EXCEPT SELECT b.id FROM public.t b WHERE b.id = 1)",
      "the UNION ALL has ORDER BY" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT a.id FROM public.t a WHERE a.x = 1 UNION ALL SELECT b.id FROM public.t b ORDER BY 1)",
      "the UNION ALL has LIMIT" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT a.id FROM public.t a WHERE a.x = 1 UNION ALL SELECT b.id FROM public.t b LIMIT 1)",
      "the UNION ALL has OFFSET" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(SELECT a.id FROM public.t a WHERE a.x = 1 UNION ALL SELECT b.id FROM public.t b OFFSET 1)",
      "the UNION ALL has a WITH" =>
        "SELECT t.id FROM public.t WHERE t.id IN " \
        "(WITH w AS (SELECT 1) SELECT a.id FROM public.t a WHERE a.x = 1 UNION ALL SELECT b.id FROM public.t b)",
      "the outer table is on the nullable side of a LEFT JOIN" =>
        "SELECT u.id FROM public.u LEFT JOIN public.t ON t.id = u.t_id " \
        "WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x IS NULL)",
      "the outer table is on the nullable side of a RIGHT JOIN" =>
        "SELECT u.id FROM public.t RIGHT JOIN public.u ON t.id = u.t_id " \
        "WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x IS NULL)",
      "the outer table is in a FULL JOIN" =>
        "SELECT u.id FROM public.t FULL JOIN public.u ON t.id = u.t_id " \
        "WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x IS NULL)",
      "the outer table is under a nullable join of joins" =>
        "SELECT u.id FROM public.u LEFT JOIN (public.t JOIN public.u u2 ON u2.t_id = t.id) ON t.id = u.t_id " \
        "WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x IS NULL)",
      "the outer name is a subquery's" =>
        "SELECT t.id FROM (SELECT * FROM public.t) t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the outer name is a join's alias" =>
        "SELECT j.id FROM (public.t JOIN public.u u2 ON u2.t_id = t.id) j " \
        "WHERE j.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the outer FROM has an item with no name of its own" =>
        "SELECT t.id FROM public.t, generate_series(1, 2) WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the outer table is read with ONLY" =>
        "SELECT t.id FROM ONLY public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the outer table's alias renames columns" =>
        "SELECT t.id FROM public.t t (id, x) WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the outer table is a CTE" =>
        "WITH t AS (SELECT * FROM public.t) SELECT t.id FROM t WHERE t.id IN " \
        "(SELECT t2.id FROM public.t t2 WHERE t2.x = 1)",
      "the query is a UNION" =>
        "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = 1) " \
        "UNION ALL SELECT u.id FROM public.u"
    }.each do |why, sql|
      it "doesn't fire when #{why}" do
        expect(rewritten(fires).size).to eq(1)
        expect(rewritten(sql)).to eq([])
      end
    end

    it "would be wrong on the keys it refuses: the rows differ if the predicates are moved anyway" do
      nullable = "SELECT t.id FROM public.t WHERE t.tag IN (SELECT t2.tag FROM public.t t2 WHERE t2.x IS NULL)"
      loose = "SELECT t.id FROM public.t WHERE t.loose IN (SELECT t2.loose FROM public.t t2 WHERE t2.x = 1)"

      expect(rows(nullable)).not_to eq(rows("SELECT t.id FROM public.t WHERE t.x IS NULL"))
      expect(rows(loose)).not_to eq(rows("SELECT t.id FROM public.t WHERE t.x = 1"))
    end
  end

  context "with the ORM query that prompted the rule" do
    let(:count_query) do
      <<~SQL.gsub(/\s+/, " ").strip
        SELECT COUNT(*) FROM assignments INNER JOIN submissions ON submissions.assignment_id = assignments.id
        AND (submissions.workflow_state <> $1) WHERE assignments.type = $2 AND (assignments.id IN ((SELECT
        assignments.id FROM assignments INNER JOIN submissions ON submissions.assignment_id = assignments.id AND
        (submissions.workflow_state <> $3) INNER JOIN content_participations ON
        content_participations.content_type = $4 AND content_participations.content_id = submissions.id WHERE
        assignments.type = $5 AND assignments.workflow_state != $6 AND assignments.context_type = $7 AND
        assignments.context_id IN ($8,$9) AND (assignments.muted IS NULL OR NOT assignments.muted) AND
        content_participations.user_id = $10 AND content_participations.workflow_state = $11) UNION ALL (SELECT
        assignments.id FROM assignments WHERE assignments.type = $12 AND assignments.workflow_state != $13 AND
        assignments.context_type = $14 AND assignments.context_id IN ($15,$16) AND assignments.id IN ($17,$18))))
        AND submissions.user_id = $19 AND submissions.workflow_state != $20 AND submissions.cached_due_date
        BETWEEN $21 AND $22
      SQL
    end
    let(:params) do
      ["deleted", "Assignment", "deleted", "Submission", "Assignment", "deleted", "Course", 10, 11, 7, "unread",
       "Assignment", "deleted", "Course", 10, 11, 2, 9, 5, "deleted", "2026-01-01", "2026-12-31"]
    end

    # Assignments 1, 2, 6, and 8 match: 1, 6, and 8 by the first arm, 2 by
    # the second. Each other one fails a single predicate, so dropping or
    # misplacing that predicate lets it in:
    #   4   deleted, with a participation (the first arm's moved predicate)
    #   5   muted
    #   7   its participation is another user's
    #   9   deleted, and in the second arm's list (that arm's moved predicate)
    #   10  another context
    #   11  another type
    #   12  its participation is of another content type
    #   13  its only participation is on a deleted submission
    # 1 has two submissions of the outer user's, one with two participations,
    # so a join in place of the EXISTS would count it more than twice. 8's
    # participation is on another user's submission, so reading the outer
    # submissions in place of the subquery's would lose it. 6's muted is NULL.
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.assignments (id int PRIMARY KEY, type text, workflow_state text, context_type text,
                                         context_id int, muted boolean);
        CREATE TABLE public.submissions (id int PRIMARY KEY, assignment_id int, user_id int, workflow_state text,
                                         cached_due_date timestamptz);
        CREATE TABLE public.content_participations (id int PRIMARY KEY, content_type text, content_id int,
                                                    user_id int, workflow_state text);
        INSERT INTO public.assignments VALUES
          (1, 'Assignment', 'published', 'Course', 10, false), (2, 'Assignment', 'published', 'Course', 11, NULL),
          (4, 'Assignment', 'deleted', 'Course', 10, false), (5, 'Assignment', 'published', 'Course', 10, true),
          (6, 'Assignment', 'published', 'Course', 10, NULL), (7, 'Assignment', 'published', 'Course', 10, false),
          (8, 'Assignment', 'published', 'Course', 10, false), (9, 'Assignment', 'deleted', 'Course', 10, false),
          (10, 'Assignment', 'published', 'Course', 12, false), (11, 'Quiz', 'published', 'Course', 10, false),
          (12, 'Assignment', 'published', 'Course', 10, false), (13, 'Assignment', 'published', 'Course', 10, false);
        INSERT INTO public.submissions
        SELECT a.id * 100 + 1, a.id, 5, 'submitted', '2026-06-01' FROM public.assignments a;
        INSERT INTO public.submissions VALUES
          (102, 1, 5, 'submitted', '2026-06-01'), (802, 8, 6, 'submitted', '2026-06-01'),
          (1302, 13, 6, 'deleted', '2026-06-01');
        INSERT INTO public.content_participations VALUES
          (1, 'Submission', 101, 7, 'unread'), (2, 'Submission', 101, 7, 'unread'), (3, 'Submission', 401, 7, 'unread'),
          (4, 'Submission', 501, 7, 'unread'), (5, 'Submission', 601, 7, 'unread'), (6, 'Submission', 701, 8, 'unread'),
          (7, 'Submission', 802, 7, 'unread'), (8, 'Submission', 901, 7, 'unread'), (9, 'Submission', 1001, 7, 'unread'),
          (10, 'Submission', 1101, 7, 'unread'), (11, 'Other', 1201, 7, 'unread'), (12, 'Submission', 1302, 7, 'unread');
      SQL
    end

    # As input qualifies it.
    def qualified(sql) = Quaack::Enclave::RelationQualifier.qualify(sql, nil, conn).sql

    it "moves each arm's assignment predicates out and leaves an EXISTS on the first arm's other tables" do
      rewrites = rewritten(qualified(count_query))

      expect(rewrites).to eq([<<~SQL.gsub(/\s+/, " ").strip])
        SELECT count(*) FROM public.assignments JOIN public.submissions ON
        submissions.assignment_id = assignments.id AND submissions.workflow_state <> $1 WHERE
        assignments.type = $2 AND ((assignments.type = $5 AND assignments.workflow_state <> $6 AND
        assignments.context_type = $7 AND assignments.context_id IN ($8, $9) AND
        (assignments.muted IS NULL OR NOT assignments.muted) AND EXISTS (SELECT 1 FROM
        public.submissions submissions_1, public.content_participations content_participations_1 WHERE
        content_participations_1.user_id = $10 AND content_participations_1.workflow_state = $11 AND
        submissions_1.assignment_id = assignments.id AND submissions_1.workflow_state <> $3 AND
        content_participations_1.content_type = $4 AND content_participations_1.content_id = submissions_1.id))
        OR (assignments.type = $12 AND assignments.workflow_state <> $13 AND assignments.context_type = $14 AND
        assignments.context_id IN ($15, $16) AND assignments.id IN ($17, $18))) AND submissions.user_id = $19
        AND submissions.workflow_state <> $20 AND submissions.cached_due_date BETWEEN $21 AND $22
      SQL
      expect(same_rows(qualified(count_query), rewrites, params)).to eq([["5"]])
    end

    it "returns the same assignment and submission rows, not only the same count" do
      sql = qualified(count_query.sub("COUNT(*)", "assignments.id, submissions.id"))

      expect(same_rows(sql, rewritten(sql), params)).to eq([%w[1 101], %w[1 102], %w[2 201], %w[6 601], %w[8 801]])
    end
  end
end
