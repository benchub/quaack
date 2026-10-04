# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/existence_in_flip"
require "quaack/enclave/rewrite_rules/literals"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' existence_in_flip, on a real server: an existence check
# under LIMIT 1 with an uncorrelated IN subquery is turned inside out, so
# the subquery's table drives, and every rewrite returns the original's
# rows.
RSpec.describe Quaack::Enclave::RewriteRules::ExistenceInFlip do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.courses (id int PRIMARY KEY, workflow_state text);
      CREATE TABLE public.enrollments (id int PRIMARY KEY, user_id int, course_id int, workflow_state text);
      CREATE TABLE public.assignments (id int PRIMARY KEY, context_id int, workflow_state text);
      CREATE TABLE public.tool_lookups (id int PRIMARY KEY, assignment_id int, tool_product_code text);
      CREATE TABLE public.submissions (id int PRIMARY KEY, assignment_id int, user_id int);
      INSERT INTO public.courses VALUES (1, 'available'), (2, 'deleted'), (3, NULL), (4, 'available');
      INSERT INTO public.enrollments VALUES
        (1, 10, 1, 'active'), (2, 10, 2, 'active'), (3, 11, 1, 'deleted'), (4, 11, 3, 'active'),
        (5, NULL, 1, 'active'), (6, 10, 1, 'active'), (7, 12, NULL, 'active'), (8, 13, 4, 'active');
      INSERT INTO public.assignments VALUES
        (1, 1, 'published'), (2, 1, 'deleted'), (3, 2, 'published'), (4, 3, 'published'), (5, NULL, 'published'),
        (6, 4, 'draft'), (7, 1, 'published');
      INSERT INTO public.tool_lookups VALUES
        (1, 1, 'turnitin'), (2, 1, 'turnitin'), (3, 3, 'turnitin'), (4, NULL, 'turnitin'), (5, 4, 'other'),
        (6, 2, NULL), (7, 5, 'turnitin'), (8, 6, 'other');
      INSERT INTO public.submissions VALUES (1, 1, 10), (2, 2, 11), (3, 6, 13), (4, NULL, 12), (5, 4, 13);
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
    binding.execute(conn, name).values
  ensure
    begin
      conn.exec("DEALLOCATE #{name}")
    rescue StandardError
      nil
    end
  end

  def runs(sql)
    original = redacted(sql)
    rows(original.sql, original.placeholder_map)
  end

  # The rewrites of sql are exactly expected, and each returns sql's rows.
  # Returns those rows.
  def expect_rewrites(sql, *expected)
    expect(rewritten(sql)).to eq(expected), sql
    want = runs(sql)
    map = redacted(sql).placeholder_map
    expected.each { expect(rows(it, map)).to eq(want), sql }
    want
  end

  # Each of sqls has one rewrite, which returns its rows. At least one of
  # them returns a row and one returns none.
  def expect_flips(*sqls)
    found = sqls.map { flip_rows(it) }
    expect(found.map(&:empty?).uniq.sort_by(&:to_s)).to eq([false, true])
  end

  # The rows of sql, which has one rewrite that returns them.
  def flip_rows(sql)
    rewrites = rewritten(sql)
    expect(rewrites.size).to eq(1), sql
    want = runs(sql)
    expect(rows(rewrites.first, redacted(sql).placeholder_map)).to eq(want), sql
    want
  end

  # Each refused query, which Postgres runs, makes no rewrite, and its
  # twin, the same query without what it refuses, makes one.
  def expect_refusals(cases)
    cases.each do |refused, twin|
      expect { conn.exec(refused) }.not_to raise_error, refused
      expect(rewritten(refused)).to eq([]), refused
      expect(rewritten(twin).size).to eq(1), twin
    end
  end

  def turnitin(code = "turnitin")
    "SELECT tool_lookups.assignment_id FROM public.tool_lookups WHERE tool_lookups.tool_product_code = '#{code}'"
  end

  def canvas(user, code: "turnitin", limit: "LIMIT 1", select: "1 AS one")
    "SELECT #{select} FROM public.enrollments JOIN public.courses ON courses.id = enrollments.course_id " \
      "JOIN public.assignments ON assignments.context_id = courses.id " \
      "WHERE enrollments.user_id = #{user} AND enrollments.workflow_state = 'active' " \
      "AND courses.workflow_state <> 'deleted' AND assignments.workflow_state = 'published' " \
      "AND assignments.id IN (#{turnitin(code)}) #{limit}"
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["existence_in_flip",
       "An existence check under LIMIT 1 is turned inside out: an uncorrelated IN subquery's table drives, and " \
       "the rest of the query becomes an EXISTS correlated on the IN's two sides."]
    )
  end

  it "makes the IN subquery's table drive the Canvas existence check" do
    want = expect_rewrites(
      canvas(10),
      "SELECT $1 AS one FROM public.tool_lookups WHERE tool_lookups.tool_product_code = $6 AND EXISTS (" \
      "SELECT 1 FROM public.enrollments JOIN public.courses ON courses.id = enrollments.course_id " \
      "JOIN public.assignments ON assignments.context_id = courses.id " \
      "WHERE enrollments.user_id = $2 AND enrollments.workflow_state = $3 AND courses.workflow_state <> $4 " \
      "AND assignments.workflow_state = $5 AND assignments.id = tool_lookups.assignment_id) LIMIT $7"
    )
    expect(want).to eq([["1"]])
  end

  it "returns a row exactly when the original does, with NULLs and duplicate matches on both sides" do
    expect_flips(canvas(10), canvas(11), canvas(12), canvas(13), canvas("NULL"), canvas(10, code: "other"),
                 canvas(13, code: "other"))
  end

  it "matches NULL to nothing, as IN does" do
    in_published = "SELECT assignments.context_id FROM public.assignments WHERE assignments.workflow_state = "
    queries = [["published", 12], ["published", 10], ["published", 11], ["draft", 13], ["draft", 10]]
    expect_flips(*queries.map do |state, user|
      "SELECT 1 AS one FROM public.enrollments WHERE enrollments.user_id = #{user} " \
        "AND enrollments.course_id IN (#{in_published}'#{state}') LIMIT 1"
    end)
  end

  it "keeps an outer join in the original FROM whole inside the EXISTS" do
    sql = lambda do |state|
      "SELECT 1 AS one FROM public.enrollments LEFT JOIN public.courses ON courses.id = enrollments.course_id " \
        "AND courses.workflow_state = 'available' WHERE courses.id IS NULL AND enrollments.course_id IN (" \
        "SELECT assignments.context_id FROM public.assignments WHERE assignments.workflow_state = '#{state}') LIMIT 1"
    end
    expect_rewrites(
      sql.call("published"),
      "SELECT $1 AS one FROM public.assignments WHERE assignments.workflow_state = $3 AND EXISTS (" \
      "SELECT 1 FROM public.enrollments LEFT JOIN public.courses ON courses.id = enrollments.course_id " \
      "AND courses.workflow_state = $2 WHERE courses.id IS NULL AND enrollments.course_id = assignments.context_id) " \
      "LIMIT $4"
    )
    expect_flips(sql.call("published"), sql.call("draft"))
  end

  it "keeps the original's CTEs at the top, where both sides can read them" do
    expect_rewrites(
      "WITH active AS (SELECT enrollments.course_id FROM public.enrollments " \
      "WHERE enrollments.workflow_state = 'active'), published AS (SELECT assignments.context_id " \
      "FROM public.assignments WHERE assignments.workflow_state = 'published') " \
      "SELECT 1 AS one FROM active WHERE active.course_id IN (SELECT published.context_id FROM published) LIMIT 1",
      "WITH active AS (SELECT enrollments.course_id FROM public.enrollments WHERE enrollments.workflow_state = $1), " \
      "published AS (SELECT assignments.context_id FROM public.assignments WHERE assignments.workflow_state = $2) " \
      "SELECT $3 AS one FROM published WHERE EXISTS (SELECT 1 FROM active " \
      "WHERE active.course_id = published.context_id) LIMIT $4"
    )
  end

  it "renames the subquery's table when the original's FROM has its name" do
    sql = lambda do |outer, inner|
      "SELECT 1 AS one FROM public.assignments WHERE assignments.workflow_state = '#{outer}' " \
        "AND assignments.context_id IN (SELECT assignments.context_id FROM public.assignments " \
        "WHERE assignments.workflow_state = '#{inner}') LIMIT 1"
    end
    expect_rewrites(
      sql.call("deleted", "published"),
      "SELECT $1 AS one FROM public.assignments assignments_1 WHERE assignments_1.workflow_state = $3 " \
      "AND EXISTS (SELECT 1 FROM public.assignments WHERE assignments.workflow_state = $2 " \
      "AND assignments.context_id = assignments_1.context_id) LIMIT $4"
    )
    expect_flips(sql.call("deleted", "published"), sql.call("deleted", "draft"))
  end

  it "renames an alias the original's FROM also uses, keeping the subquery's other names" do
    sql = lambda do |code|
      "SELECT 1 AS one FROM public.submissions AS l WHERE l.user_id = 13 AND l.assignment_id IN (" \
        "SELECT l.assignment_id FROM public.tool_lookups AS l JOIN public.assignments " \
        "ON assignments.id = l.assignment_id WHERE l.tool_product_code = '#{code}') LIMIT 1"
    end
    expect_rewrites(
      sql.call("other"),
      "SELECT $1 AS one FROM public.tool_lookups l_1 JOIN public.assignments ON assignments.id = l_1.assignment_id " \
      "WHERE l_1.tool_product_code = $3 AND EXISTS (SELECT 1 FROM public.submissions l WHERE l.user_id = $2 " \
      "AND l.assignment_id = l_1.assignment_id) LIMIT $4"
    )
    expect_flips(sql.call("other"), sql.call("turnitin"))
  end

  it "qualifies an unqualified selected column, so the original's FROM can't capture it" do
    sql = lambda do |user|
      "SELECT 1 AS one FROM public.submissions WHERE submissions.user_id = #{user} " \
        "AND submissions.assignment_id IN (SELECT assignment_id FROM public.tool_lookups " \
        "WHERE tool_product_code = 'turnitin') LIMIT 1"
    end
    expect_rewrites(
      sql.call(10),
      "SELECT $1 AS one FROM public.tool_lookups WHERE tool_product_code = $3 AND EXISTS (SELECT 1 " \
      "FROM public.submissions WHERE submissions.user_id = $2 " \
      "AND submissions.assignment_id = tool_lookups.assignment_id) LIMIT $4"
    )
    expect_flips(sql.call(10), sql.call(11), sql.call(13), sql.call(12))
  end

  it "makes one rewrite per IN that qualifies, each leaving the others inside its EXISTS" do
    sql = "SELECT 1 AS one FROM public.assignments WHERE assignments.workflow_state = 'published' " \
          "AND assignments.id IN (#{turnitin}) AND assignments.context_id IN (SELECT courses.id " \
          "FROM public.courses WHERE courses.workflow_state = 'available') LIMIT 1"
    expect(expect_rewrites(
             sql,
             "SELECT $1 AS one FROM public.tool_lookups WHERE tool_lookups.tool_product_code = $3 AND EXISTS (" \
             "SELECT 1 FROM public.assignments WHERE assignments.workflow_state = $2 AND assignments.context_id IN (" \
             "SELECT courses.id FROM public.courses WHERE courses.workflow_state = $4) " \
             "AND assignments.id = tool_lookups.assignment_id) LIMIT $5",
             "SELECT $1 AS one FROM public.courses WHERE courses.workflow_state = $4 AND EXISTS (" \
             "SELECT 1 FROM public.assignments WHERE assignments.workflow_state = $2 AND assignments.id IN (" \
             "SELECT tool_lookups.assignment_id FROM public.tool_lookups WHERE tool_lookups.tool_product_code = $3) " \
             "AND assignments.context_id = courses.id) LIMIT $5"
           )).to eq([["1"]])
  end

  it "drops a plain DISTINCT from the subquery, which IN doesn't count" do
    expect_rewrites(
      "SELECT 1 AS one FROM public.assignments WHERE assignments.id IN (SELECT DISTINCT tool_lookups.assignment_id " \
      "FROM public.tool_lookups) LIMIT 1",
      "SELECT $1 AS one FROM public.tool_lookups WHERE EXISTS (SELECT 1 FROM public.assignments " \
      "WHERE assignments.id = tool_lookups.assignment_id) LIMIT $2"
    )
  end

  it "flips when a placeholder's type comes from its literal, as in generate_series's bounds" do
    sql = lambda do |low, high|
      "SELECT 1 AS one FROM generate_series(#{low}, #{high}) AS g(n) WHERE g.n IN (SELECT courses.id " \
        "FROM public.courses WHERE courses.workflow_state = 'available') LIMIT 1"
    end
    expect_flips(sql.call(1, 3), sql.call(2, 3), sql.call(4, 9), sql.call(5, 9))
  end

  it "keeps an ORDER BY of columns or positions as ORDER BY 1, since every row is the same constants" do
    expect_rewrites(
      canvas(10, limit: "ORDER BY enrollments.id DESC, 1 LIMIT 1"),
      "SELECT $1 AS one FROM public.tool_lookups WHERE tool_lookups.tool_product_code = $6 AND EXISTS (" \
      "SELECT 1 FROM public.enrollments JOIN public.courses ON courses.id = enrollments.course_id " \
      "JOIN public.assignments ON assignments.context_id = courses.id " \
      "WHERE enrollments.user_id = $2 AND enrollments.workflow_state = $3 AND courses.workflow_state <> $4 " \
      "AND assignments.workflow_state = $5 AND assignments.id = tool_lookups.assignment_id) ORDER BY 1 LIMIT $7"
    )
    %w[enrollments.id 1].each do |key|
      expect_flips(*[10, 11, 12, 13].map { canvas(it, limit: "ORDER BY #{key} LIMIT 1") })
    end
    expect_flips(*%w[turnitin other nothing].map do |code|
      "SELECT 1 AS one FROM public.assignments AS a WHERE a.id IN (#{turnitin(code)}) " \
        "ORDER BY a.workflow_state, a.id DESC LIMIT 1"
    end)
  end

  it "refuses an ORDER BY that could fail on the original's rows, which the rewrite wouldn't sort" do
    sql = canvas(10, limit: "ORDER BY 1 / (enrollments.id - enrollments.id) LIMIT 1")
    expect { conn.exec(sql) }.to raise_error(PG::DivisionByZero)
    expect(rewritten(sql)).to eq([])
    conn.exec("CREATE TABLE public.docs (id int, body json, bodies json[]); " \
              "INSERT INTO public.docs VALUES (1, '{}', '{}'), (1, '[]', '{[]}')")
    %w[docs docs.bodies d.id].each do |key|
      whole = "SELECT 1 AS one FROM public.docs#{" AS d(x, y, id)" if key.start_with?("d.")} WHERE " \
              "#{key.start_with?("d.") ? "d.x" : "docs.id"} IN (SELECT courses.id FROM public.courses) " \
              "ORDER BY #{key} LIMIT 1"
      expect { conn.exec(whole) }.to raise_error(PG::UndefinedFunction)
      expect(rewritten(whole)).to eq([])
    end
    expect_refusals(
      [[canvas(10, limit: "ORDER BY enrollments.id + 0 LIMIT 1"), canvas(10, limit: "ORDER BY enrollments.id LIMIT 1")],
       [canvas(10, limit: "ORDER BY enrollments.id USING < LIMIT 1"),
        canvas(10, limit: "ORDER BY enrollments.id LIMIT 1")],
       [canvas(10, limit: "ORDER BY enrollments.id LIMIT 1", select: ""), canvas(10, select: "")]]
    )
  end

  it "takes a cast constant in the select list as a constant" do
    expect_rewrites(
      canvas(10, select: "CAST(1 AS bigint)::text AS one"),
      "SELECT $1::bigint::text AS one FROM public.tool_lookups WHERE tool_lookups.tool_product_code = $6 " \
      "AND EXISTS (SELECT 1 FROM public.enrollments JOIN public.courses ON courses.id = enrollments.course_id " \
      "JOIN public.assignments ON assignments.context_id = courses.id " \
      "WHERE enrollments.user_id = $2 AND enrollments.workflow_state = $3 AND courses.workflow_state <> $4 " \
      "AND assignments.workflow_state = $5 AND assignments.id = tool_lookups.assignment_id) LIMIT $7"
    )
    expect_flips(*[10, 11, 12, 13].map { canvas(it, select: "1::integer AS one, 'x'::text") })
    expect_refusals(
      [[canvas(10, select: "enrollments.id::text"), canvas(10, select: "1::text")],
       [canvas(10, select: "(1 + 1)::text"), canvas(10, select: "1::text")]]
    )
  end

  it "refuses an ORDER BY when Postgres can't sort the first output column, which ORDER BY 1 would" do
    conn.exec("CREATE TYPE public.wrapped AS (body json)")
    sql = canvas(10, select: "'(\"{}\")'::public.wrapped AS one", limit: "ORDER BY enrollments.id LIMIT 1")
    expect(conn.exec(sql).values.size).to eq(1)
    expect(rewritten(sql)).to eq([])
    expect(rewritten(canvas(10, select: "'(\"{}\")'::public.wrapped AS one")).size).to eq(1)
  end

  it "qualifies an unqualified selected column with the one table of several that has it" do
    expect_rewrites(
      "SELECT 1 AS one FROM public.submissions WHERE submissions.user_id = 10 AND submissions.assignment_id IN (" \
      "SELECT assignment_id FROM public.tool_lookups JOIN public.courses ON courses.id = tool_lookups.id) LIMIT 1",
      "SELECT $1 AS one FROM public.tool_lookups JOIN public.courses ON courses.id = tool_lookups.id " \
      "WHERE EXISTS (SELECT 1 FROM public.submissions WHERE submissions.user_id = $2 " \
      "AND submissions.assignment_id = tool_lookups.assignment_id) LIMIT $3"
    )
    expect_flips(*[10, 11, 12, 13].flat_map do |user|
      ["SELECT 1 AS one FROM public.submissions WHERE submissions.user_id = #{user} AND submissions.assignment_id " \
       "IN (SELECT assignment_id FROM public.tool_lookups JOIN public.courses ON courses.id = tool_lookups.id) " \
       "LIMIT 1",
       "SELECT 1 AS one FROM public.submissions WHERE submissions.user_id = #{user} AND submissions.assignment_id " \
       "IN (SELECT assignment_id FROM public.courses, public.tool_lookups " \
       "WHERE courses.id = tool_lookups.id AND courses.workflow_state = 'available') LIMIT 1"]
    end)
  end

  it "refuses an unqualified selected column that more than one or none of its tables has" do
    expect_no_flip(
      "SELECT 1 AS one FROM public.assignments WHERE assignments.id >= 6 AND assignments.id IN (" \
      "SELECT id FROM public.submissions FULL JOIN public.tool_lookups USING (id)) LIMIT 1",
      "SELECT 1 AS one FROM public.submissions WHERE submissions.assignment_id IN (" \
      "SELECT user_id FROM public.tool_lookups, public.courses) LIMIT 1",
      "SELECT 1 AS one FROM public.submissions WHERE submissions.assignment_id IN (" \
      "SELECT assignment_id FROM public.tool_lookups, (SELECT 1 AS k) AS s) LIMIT 1"
    )
  end

  it "moves an expression the subquery selects, qualifying and renaming its columns" do
    expect_rewrites(
      "SELECT 1 AS one FROM public.tool_lookups WHERE tool_lookups.id + 0 IN (SELECT coalesce(assignment_id, " \
      "tool_lookups.id) - 1 FROM public.tool_lookups JOIN public.courses ON courses.id = tool_lookups.id) LIMIT 1",
      "SELECT $1 AS one FROM public.tool_lookups tool_lookups_1 JOIN public.courses " \
      "ON courses.id = tool_lookups_1.id WHERE EXISTS (SELECT 1 FROM public.tool_lookups " \
      "WHERE (tool_lookups.id + $2) = (COALESCE(tool_lookups_1.assignment_id, tool_lookups_1.id) - $3)) LIMIT $4"
    )
    expect_flips(*%w[turnitin other nothing].flat_map do |code|
      ["SELECT 1 AS one FROM public.assignments WHERE assignments.id IN (SELECT tool_lookups.assignment_id + 0 " \
       "FROM public.tool_lookups WHERE tool_lookups.tool_product_code = '#{code}') LIMIT 1",
       "SELECT 1 AS one FROM public.submissions WHERE submissions.user_id = 13 AND submissions.assignment_id IN (" \
       "SELECT tool_lookups.id * 0 + assignment_id FROM public.tool_lookups " \
       "WHERE tool_lookups.tool_product_code = '#{code}') LIMIT 1",
       "SELECT 1 AS one FROM public.submissions WHERE submissions.user_id = 13 AND submissions.assignment_id IN (" \
       "SELECT coalesce(assignment_id, 6) FROM public.tool_lookups " \
       "JOIN public.courses ON courses.id = tool_lookups.id " \
       "WHERE tool_lookups.tool_product_code = '#{code}') LIMIT 1"]
    end)
    expect_flips(*["courses.id", "courses.id + 4"].map do |x|
      "SELECT 1 AS one FROM public.courses JOIN public.tool_lookups ON tool_lookups.id = courses.id " \
        "WHERE courses.id = 2 AND #{x} IN (SELECT courses.id * 0 + tool_lookups.assignment_id " \
        "FROM public.tool_lookups JOIN public.courses ON courses.id = tool_lookups.assignment_id) LIMIT 1"
    end)
  end

  it "refuses a selected expression it can't move" do
    conn.exec("CREATE TABLE public.codes (code char(3)); INSERT INTO public.codes VALUES ('a')")
    expect_no_flip(
      "SELECT 1 AS one FROM public.codes WHERE codes.code IN (SELECT 'a ' FROM public.courses) LIMIT 1",
      "SELECT 1 AS one FROM public.codes WHERE codes.code IN (SELECT * FROM public.codes) LIMIT 1",
      "SELECT 1 AS one FROM public.assignments WHERE assignments.id IN (SELECT count(*) " \
      "FROM public.tool_lookups) LIMIT 1",
      "SELECT 1 AS one FROM public.submissions WHERE submissions.user_id = 11 AND submissions.assignment_id IN (" \
      "SELECT (SELECT courses.id FROM public.courses WHERE courses.id = assignment_id) FROM public.tool_lookups " \
      "WHERE tool_lookups.tool_product_code = 'other') LIMIT 1",
      "SELECT 1 AS one FROM public.submissions WHERE submissions.assignment_id IN (SELECT (SELECT courses.id " \
      "FROM public.courses WHERE id = 2) FROM public.tool_lookups WHERE tool_lookups.id = 5) LIMIT 1",
      "SELECT 1 AS one FROM public.assignments WHERE assignments.id IN (SELECT max(tool_lookups.assignment_id) " \
      "FROM public.tool_lookups) LIMIT 1",
      "SELECT 1 AS one FROM public.assignments WHERE assignments.id IN (SELECT generate_series(1, " \
      "tool_lookups.assignment_id) FROM public.tool_lookups) LIMIT 1",
      "SELECT 1 AS one FROM public.assignments WHERE assignments.id IN (SELECT row_number() OVER () " \
      "FROM public.tool_lookups) LIMIT 1",
      "SELECT 1 AS one FROM public.submissions WHERE submissions.assignment_id IN (SELECT " \
      "tool_lookups.assignment_id + user_id - user_id FROM public.tool_lookups, public.courses) LIMIT 1"
    )
  end

  it "renames a table its subqueries read, when none of them has a FROM item of that name" do
    expect_rewrites(
      "SELECT 1 AS one FROM public.tool_lookups WHERE tool_lookups.id IN (SELECT tool_lookups.assignment_id " \
      "FROM public.tool_lookups WHERE EXISTS (SELECT 1 FROM public.courses WHERE courses.id = " \
      "tool_lookups.assignment_id AND courses.workflow_state = 'available')) LIMIT 1",
      "SELECT $1 AS one FROM public.tool_lookups tool_lookups_1 WHERE EXISTS (SELECT $2 FROM public.courses " \
      "WHERE courses.id = tool_lookups_1.assignment_id AND courses.workflow_state = $3) AND EXISTS (SELECT 1 " \
      "FROM public.tool_lookups WHERE tool_lookups.id = tool_lookups_1.assignment_id) LIMIT $4"
    )
    expect_flips(*%w[turnitin other].map do |code|
      "SELECT 1 AS one FROM public.tool_lookups WHERE tool_lookups.tool_product_code = '#{code}' AND " \
        "tool_lookups.id IN (SELECT tool_lookups.assignment_id FROM public.tool_lookups WHERE EXISTS (SELECT 1 " \
        "FROM public.courses WHERE courses.id = tool_lookups.assignment_id AND " \
        "courses.workflow_state = 'available')) LIMIT 1"
    end)
  end

  it "refuses to rename a table when a subquery of its has a FROM item of that name" do
    conn.exec("CREATE FUNCTION public.tool_lookups() RETURNS TABLE (id int) LANGUAGE sql IMMUTABLE AS 'SELECT 3'")
    inners = ["public.tool_lookups WHERE tool_lookups.tool_product_code IS NULL",
              "public.courses AS tool_lookups WHERE tool_lookups.id = 3",
              "generate_series(3, 3) AS tool_lookups(id) WHERE tool_lookups.id = 3",
              "public.tool_lookups() WHERE tool_lookups.id = 3"]
    expect_no_flip(*inners.map do |inner|
      "SELECT 1 AS one FROM public.tool_lookups WHERE tool_lookups.id = 1 AND tool_lookups.id IN (SELECT " \
        "tool_lookups.assignment_id FROM public.tool_lookups WHERE EXISTS (SELECT 1 FROM #{inner})) LIMIT 1"
    end)
  end

  # Each of sqls makes no rewrite, and any it did make would return its
  # rows.
  def expect_no_flip(*sqls)
    aggregate_failures do
      sqls.each do |sql|
        want = runs(sql)
        map = redacted(sql).placeholder_map
        rewritten(sql).each { expect([sql, rows(it, map)]).to eq([sql, want]) }
        expect(rewritten(sql)).to eq([]), sql
      end
    end
  end

  describe "a bare name that could be read as a whole row" do
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.posts (id int PRIMARY KEY, body text);
        CREATE TABLE public.holders (id int PRIMARY KEY, posts int);
        INSERT INTO public.posts VALUES (1, 'a'), (2, 'b');
        INSERT INTO public.holders VALUES (1, NULL), (2, 5);
      SQL
    end

    it "refuses one in the original's conditions, which the subquery's column of that name would capture" do
      expect_no_flip(
        "SELECT 1 AS one FROM public.posts WHERE posts.id IN (SELECT holders.id FROM public.holders) " \
        "AND posts IS NULL LIMIT 1",
        "SELECT 1 AS one FROM public.courses AS posts WHERE posts.id IN (SELECT holders.id FROM public.holders) " \
        "AND posts IS NULL LIMIT 1",
        "SELECT 1 AS one FROM public.posts WHERE posts.id IN (SELECT holders.id FROM public.holders) " \
        "AND EXISTS (SELECT 1 FROM public.courses WHERE posts IS NULL) LIMIT 1",
        "SELECT 1 AS one FROM public.posts JOIN public.courses ON posts IS NULL " \
        "WHERE posts.id IN (SELECT holders.id FROM public.holders) LIMIT 1",
        "SELECT 1 AS one FROM public.posts WHERE CASE WHEN posts IS NULL THEN posts.id END " \
        "IN (SELECT holders.id FROM public.holders) LIMIT 1"
      )
    end

    it "refuses one in the subquery, which the original's column of that name had read" do
      expect_no_flip(
        "SELECT 1 AS one FROM public.holders WHERE holders.id IN (SELECT posts.id FROM public.posts " \
        "WHERE posts IS NULL) LIMIT 1"
      )
    end

    it "still flips when a whole row is written qualified" do
      expect_flips(
        "SELECT 1 AS one FROM public.posts WHERE posts.id IN (SELECT holders.id FROM public.holders) " \
        "AND posts.* IS NULL LIMIT 1",
        "SELECT 1 AS one FROM public.posts WHERE posts.id IN (SELECT holders.id FROM public.holders) " \
        "AND posts.* IS NOT NULL LIMIT 1"
      )
    end
  end

  it "refuses a query that isn't an existence check under LIMIT 1" do
    expect_refusals(
      [[canvas(10, limit: "LIMIT 2"), canvas(10)],
       [canvas(10, limit: ""), canvas(10)],
       [canvas(10, limit: "LIMIT NULL"), canvas(10)],
       [canvas(10, limit: "LIMIT 1 OFFSET 0"), canvas(10)],
       [canvas(10, select: "enrollments.id"), canvas(10, select: "1")],
       [canvas(10, select: "1, enrollments.id"), canvas(10, select: "1, 2")],
       [canvas(10, select: "count(*)"), canvas(10, select: "1")],
       [canvas(10, select: "DISTINCT 1"), canvas(10, select: "1")],
       [canvas(10, limit: "GROUP BY enrollments.id LIMIT 1"), canvas(10)],
       [canvas(10, limit: "HAVING count(*) > 0 LIMIT 1"), canvas(10)],
       [canvas(10, limit: "WINDOW w AS (ORDER BY enrollments.id) LIMIT 1"), canvas(10)],
       [canvas(10, limit: "GROUP BY 1 LIMIT 1"), canvas(10)],
       [canvas(10, limit: "WINDOW w AS () LIMIT 1"), canvas(10)]]
    )
  end

  it "refuses an IN it can't flip" do
    qualifying = "SELECT 1 FROM public.assignments WHERE assignments.id IN (#{turnitin}) LIMIT 1"
    expect_refusals(
      [["SELECT 1 FROM public.assignments WHERE assignments.id IN (#{turnitin} " \
        "AND tool_lookups.id <> assignments.id) LIMIT 1", qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id IN (#{turnitin} AND context_id = 1) LIMIT 1",
        qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id IN (SELECT assignments.context_id " \
        "FROM public.tool_lookups) LIMIT 1", qualifying],
       ["SELECT 1 FROM public.assignments WHERE EXISTS (#{turnitin}) LIMIT 1", qualifying],
       ["SELECT 1 FROM public.assignments JOIN (public.submissions JOIN public.courses ON courses.id = " \
        "submissions.id) AS j ON j.user_id = assignments.id WHERE assignments.id IN (#{turnitin}) LIMIT 1",
        "SELECT 1 FROM public.assignments JOIN (public.submissions JOIN public.courses ON courses.id = " \
        "submissions.id) ON submissions.user_id = assignments.id WHERE assignments.id IN (#{turnitin}) LIMIT 1"],
       ["SELECT 1 FROM public.assignments WHERE assignments.id IN (#{turnitin} LIMIT 5) LIMIT 1", qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id IN (#{turnitin} OFFSET 0) LIMIT 1", qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id IN (SELECT max(tool_lookups.assignment_id) " \
        "FROM public.tool_lookups) LIMIT 1", qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id IN (SELECT tool_lookups.assignment_id " \
        "FROM public.tool_lookups GROUP BY tool_lookups.assignment_id HAVING count(*) > 1) LIMIT 1", qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id IN (#{turnitin} UNION " \
        "SELECT submissions.assignment_id FROM public.submissions) LIMIT 1", qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id IN (#{turnitin} AND random() < 2) LIMIT 1",
        qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id IN (#{turnitin}) AND random() < 2 LIMIT 1",
        qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id IN (SELECT DISTINCT ON (tool_lookups.id) " \
        "tool_lookups.assignment_id FROM public.tool_lookups) LIMIT 1", qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id = ANY (#{turnitin}) LIMIT 1", qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id NOT IN (#{turnitin}) LIMIT 1", qualifying],
       ["SELECT 1 FROM public.assignments WHERE assignments.id IN (#{turnitin}) OR assignments.id = 1 LIMIT 1",
        qualifying]]
    )
  end

  it "refuses a selected column it can't qualify or rename safely" do
    expect_refusals(
      [["SELECT 1 FROM public.tool_lookups WHERE tool_lookups.id IN (SELECT tool_lookups.assignment_id " \
        "FROM public.tool_lookups WHERE public.tool_lookups.tool_product_code = 'x') LIMIT 1",
        "SELECT 1 FROM public.tool_lookups AS t WHERE t.id IN (SELECT tool_lookups.assignment_id " \
        "FROM public.tool_lookups WHERE public.tool_lookups.tool_product_code = 'x') LIMIT 1"]]
    )
  end

  it "makes nothing without the literal oracle, which it needs to read the limit" do
    expect(rule.rewrites(PgQuery.parse(redacted(canvas(10)).sql), catalog, nil)).to eq([])
  end

  it "is part of RULES and gives the generator its rewrite" do
    generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(redacted(canvas(10)).sql), catalog,
                                                       literals_for(canvas(10)).last)
    expect(generated.rewrites.map { it.rules.map(&:name) }).to include(["existence_in_flip"])
  end
end
