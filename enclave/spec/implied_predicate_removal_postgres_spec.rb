# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/implied_predicate_removal"
require "quaack/enclave/rewrite_rules/literals"
require_relative "support/production_server"

# DESIGN.md 6c's implied_predicate_removal, on a real server: redundant
# Rails predicates are removed only when a column equality proves them, and
# the proof about placeholder values stays inside Postgres.
RSpec.describe Quaack::Enclave::RewriteRules::ImpliedPredicateRemoval do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  before do
    conn.exec(<<~SQL)
      CREATE COLLATION public.loose (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
      CREATE TABLE public.enrollments (
        id int PRIMARY KEY,
        workflow_state text,
        type text,
        score int,
        loose text COLLATE public.loose
      );
      CREATE TABLE public.assignments (id int PRIMARY KEY, type text);
      CREATE TABLE public.submissions (id int PRIMARY KEY, assignment_id int);
      INSERT INTO public.enrollments VALUES
        (1, 'active', 'TeacherEnrollment', 15, 'a'),
        (2, 'active', 'StudentEnrollment', 5, 'b'),
        (3, 'deleted', 'TeacherEnrollment', 15, 'c'),
        (4, NULL, 'TeacherEnrollment', NULL, 'd');
      INSERT INTO public.assignments VALUES (1, 'Assignment'), (2, 'Other');
      INSERT INTO public.submissions VALUES (1, 1), (2, 2);
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def literals_for(sql)
    redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))
    literals = Quaack::Enclave::RewriteRules::Literals.new(
      conn,
      redacted.placeholder_map,
      redacted.placeholder_shapes
    )
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
      conn.exec("DEALLOCATE #{name}") if name
    rescue StandardError
      nil
    end
  end

  def same_rows(redacted, rewrite)
    original = Quaack::Enclave::Redaction.query(PgQuery.parse(redacted))
    expect(rows(rewrite, original.placeholder_map)).to eq(rows(original.sql, original.placeholder_map))
  end

  describe Quaack::Enclave::RewriteRules::Literals do
    it "evaluates boolean expressions over bound placeholders" do
      _redacted, literals = literals_for(
        "SELECT enrollments.id FROM public.enrollments WHERE enrollments.score = 5"
      )

      expect(literals.holds?("$1::integer = 5")).to be(true)
      expect(literals.holds?("$1::integer > 10")).to be(false)
    end

    it "compares placeholder text and shape without treating different values as equal" do
      _redacted, literals = literals_for(
        "SELECT enrollments.id FROM public.enrollments WHERE " \
        "enrollments.score = 1 AND enrollments.score = 2 AND " \
        "enrollments.type = 'active' AND enrollments.workflow_state = 'active'"
      )

      expect(literals.same?("$1", "$2")).to be(false)
      expect(literals.same?("$3", "$4")).to be(true)
    end
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["implied_predicate_removal",
       "Redundant predicates in a WHERE or inner-join ON are removed when an equality on the same column proves them."]
    )
  end

  it "removes Rails workflow-state and STI predicates implied by an equality" do
    sql = "SELECT enrollments.id FROM public.enrollments WHERE " \
          "enrollments.workflow_state <> 'deleted' AND enrollments.workflow_state = 'active' AND " \
          "enrollments.type IN ('StudentEnrollment', 'TeacherEnrollment') AND " \
          "enrollments.type = 'TeacherEnrollment'"

    rewrites = rewritten(sql)
    expect(rewrites.size).to eq(1)
    rewrite = rewrites.first

    expect(rewrite).to eq(
      "SELECT enrollments.id FROM public.enrollments WHERE " \
      "enrollments.workflow_state = $2 AND enrollments.type = $5"
    )
    same_rows(sql, rewrite)
  end

  it "removes range predicates and exact duplicates, keeping the first placeholder copy" do
    sql = "SELECT enrollments.id FROM public.enrollments WHERE " \
          "enrollments.score >= 10 AND enrollments.score BETWEEN 10 AND 20 AND " \
          "enrollments.score = 15 AND enrollments.score IS NOT NULL AND enrollments.score IS NOT NULL"

    expect(rewritten(sql)).to eq(
      ["SELECT enrollments.id FROM public.enrollments WHERE enrollments.score = $4 AND " \
       "enrollments.score IS NOT NULL"]
    )
  end

  it "keeps contradictory stacked scopes that the equality does not prove" do
    {
      "workflow_state = 'active' AND workflow_state = 'deleted'" =>
        "enrollments.workflow_state = 'active' AND enrollments.workflow_state = 'deleted'",
      "type = 'TeacherEnrollment' AND type IN ('StudentEnrollment', 'TaEnrollment')" =>
        "enrollments.type = 'TeacherEnrollment' AND enrollments.type IN ('StudentEnrollment', 'TaEnrollment')",
      "score = 5 AND score > 10" =>
        "enrollments.score = 5 AND enrollments.score > 10",
      "type = 'TeacherEnrollment' AND type NOT IN ('TeacherEnrollment', 'StudentEnrollment')" =>
        "enrollments.type = 'TeacherEnrollment' AND " \
        "enrollments.type NOT IN ('TeacherEnrollment', 'StudentEnrollment')"
    }.each_value do |where|
      sql = "SELECT enrollments.id FROM public.enrollments WHERE #{where}"

      expect(rewritten(sql)).to eq([])
    end
  end

  it "does not treat equalities with different literals as exact duplicates" do
    sql = "SELECT enrollments.id FROM public.enrollments WHERE enrollments.score = 1 AND enrollments.score = 2"

    expect(rewritten(sql)).to eq([])
  end

  it "keeps one of two equalities that prove each other with different literal text" do
    sql = "SELECT enrollments.id FROM public.enrollments WHERE enrollments.score = 5 AND enrollments.score = 5.0"

    rewrites = rewritten(sql)
    expect(rewrites.size).to eq(1)
    expect(rewrites.first).to eq("SELECT enrollments.id FROM public.enrollments WHERE enrollments.score = $2")
    same_rows(sql, rewrites.first)
  end

  it "keeps one of two equal timestamp equalities written differently" do
    conn.exec(<<~SQL)
      CREATE TABLE public.events (id int PRIMARY KEY, created_at timestamp);
      INSERT INTO public.events VALUES (1, '2020-01-01'), (2, '2020-01-02'), (3, NULL);
    SQL
    sql = "SELECT events.id FROM public.events WHERE " \
          "events.created_at = '2020-01-01' AND events.created_at = '2020-01-01 00:00:00'"

    rewrites = rewritten(sql)
    expect(rewrites.size).to eq(1)
    expect(rewrites.first).to eq("SELECT events.id FROM public.events WHERE events.created_at = $2")
    same_rows(sql, rewrites.first)
  end

  it "uses inner-join ON conjuncts as proofs and drops the duplicate from WHERE" do
    sql = "SELECT submissions.id FROM public.submissions JOIN public.assignments " \
          "ON assignments.id = submissions.assignment_id AND assignments.type = 'Assignment' " \
          "WHERE assignments.type = 'Assignment'"

    expect(rewritten(sql)).to eq(
      ["SELECT submissions.id FROM public.submissions JOIN public.assignments " \
       "ON assignments.id = submissions.assignment_id AND assignments.type = $1"]
    )
  end

  it "never uses an outer-join ON conjunct as proof and never moves it" do
    sql = "SELECT submissions.id FROM public.submissions LEFT JOIN public.assignments " \
          "ON assignments.id = submissions.assignment_id AND assignments.type = 'Assignment' " \
          "WHERE assignments.type <> 'Other'"

    expect(rewritten(sql)).to eq([])
  end

  it "refuses a column with a nondeterministic collation" do
    sql = "SELECT enrollments.id FROM public.enrollments WHERE " \
          "enrollments.loose <> 'z' AND enrollments.loose = 'a'"

    expect(rewritten(sql)).to eq([])
  end

  it "binds literal values as parameters, so quotes and semicolons cannot inject" do
    conn.exec("INSERT INTO public.enrollments VALUES (5, 'active''; SELECT 1; --', 'TeacherEnrollment', 20, 'e')")
    sql = "SELECT enrollments.id FROM public.enrollments WHERE " \
          "enrollments.workflow_state IN ('deleted', 'active''; SELECT 1; --') AND " \
          "enrollments.workflow_state = 'active''; SELECT 1; --'"

    rewrites = rewritten(sql)
    expect(rewrites.size).to eq(1)
    rewrite = rewrites.first

    expect(rewrite).to eq(
      "SELECT enrollments.id FROM public.enrollments WHERE enrollments.workflow_state = $3"
    )
    same_rows(sql, rewrite)
  end

  it "doesn't change the parse it was given" do
    redacted, literals = literals_for(
      "SELECT enrollments.id FROM public.enrollments WHERE " \
      "enrollments.workflow_state <> 'deleted' AND enrollments.workflow_state = 'active'"
    )
    parse = PgQuery.parse(redacted)
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

    rule.rewrites(parse, catalog, literals)

    expect(parse.tree).to eq(before)
  end
end
