# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/atom_position"
require "quaack/enclave/deparse"
require "quaack/enclave/predicate_atoms"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/existence_in_flip"
require "quaack/enclave/rewrite_rules/implied_predicate_removal"
require "quaack/enclave/rewrite_rules/literals"
require "quaack/enclave/rewrite_rules/transitive_predicate_copy"
require_relative "support/production_server"

# DESIGN.md's unchanged-atoms, on the rewrites the real mechanical rules
# write from a real catalog: with every atom of the original taken as
# untested, which does AtomPosition call unchanged? The rules copy atom text
# and change its effect, so each case that must stay "changed" checks the
# atom's text is in the rewrite all the same.
RSpec.describe Quaack::Enclave::AtomPosition do
  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }
  let(:rules) { Quaack::Enclave::RewriteRules }
  let(:columns) { Class.new { def fetch(*) = %w[id x y t_id] }.new }

  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.t (id int PRIMARY KEY, x int, loose int NOT NULL);
      CREATE TABLE public.u (id int PRIMARY KEY, t_id int, y int);
      CREATE TABLE public.a (id int PRIMARY KEY, title text);
      CREATE TABLE public.s (id int PRIMARY KEY, a_id int, user_id int);
      CREATE TABLE public.cp (id int PRIMARY KEY, s_id int, user_id int);
      CREATE TABLE public.users (id int PRIMARY KEY, account_id int NOT NULL, ref int);
      CREATE TABLE public.memberships (id int PRIMARY KEY, user_id int NOT NULL, group_id int NOT NULL);
      CREATE TABLE public.courses (id int PRIMARY KEY, workflow_state text);
      CREATE TABLE public.enrollments (id int PRIMARY KEY, user_id int, course_id int, workflow_state text,
                                       type text, score int);
      CREATE TABLE public.assignments (id int PRIMARY KEY, context_id int, workflow_state text);
      CREATE TABLE public.tool_lookups (id int PRIMARY KEY, assignment_id int, tool_product_code text);
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  def with_literals(sql)
    query = redacted(sql)
    [query.sql, Quaack::Enclave::RewriteRules::Literals.new(conn, query.placeholder_map)]
  end

  # The rule's rewrites of sql (literals already as $n, or redacted first
  # when the rule needs the literal oracle), each as SQL, with the original
  # SQL they come from.
  def rewrites(rule, sql, literals: false)
    original, oracle = literals ? with_literals(sql) : [sql, nil]
    args = [PgQuery.parse(original), catalog, *oracle]
    [original, rule.rewrites(*args).map { Quaack::Enclave::Deparse.faithfully(it.tree) }]
  end

  # Every atom of the original, each shape with whether it's unchanged in
  # the candidate, in the original's atom order.
  def verdicts(original, candidate)
    atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(original), column_names: columns)
    atoms.map(&:shape).zip(described_class.unchanged(original, candidate, atoms.map(&:path))).to_h
  end

  # The one rewrite the rule makes of sql, and its verdicts.
  def verdicts_of(rule, sql, literals: false)
    original, made = rewrites(rule, sql, literals:)
    expect(made.size).to eq(1), "#{rule.name} made #{made.size} rewrites of #{sql}"
    [verdicts(original, made.first), made.first]
  end

  it "calls only the conjuncts key_in_self_join left in the outer WHERE unchanged" do
    sql = "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = $1) AND t.loose = $2"
    got, rewrite = verdicts_of(rules::KeyInSelfJoin.new, sql)

    expect(rewrite).to eq("SELECT t.id FROM public.t WHERE t.x = $1 AND t.loose = $2")
    expect(got).to eq("t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.x = $1)" => false, "t2.x = $1" => false,
                      "t.loose = $2" => true)
  end

  it "calls every atom changed when or_to_union copies each into a UNION arm" do
    sql = "SELECT a.id, a.title FROM public.a JOIN public.s ON s.a_id = a.id WHERE s.user_id = $1 AND " \
          "(EXISTS (SELECT 1 FROM public.cp WHERE cp.s_id = s.id AND cp.user_id = $2) OR a.id IN ($3, $4))"
    got, rewrite = verdicts_of(rules::OrToUnion.new, sql)

    expect(rewrite).to include("UNION")
    expect(got.keys).to include("s.user_id = $1", "cp.user_id = $2", "a.id IN ($3, $4)")
    expect(got.values).to all(be(false))
    expect(rewrite).to include("s.user_id = $1").and include("cp.user_id = $2").and include("a.id IN ($3, $4)")
  end

  it "calls the conjunct beside a NOT IN unchanged, and the NOT IN and its subquery's atoms changed" do
    sql = "SELECT users.* FROM public.users WHERE users.account_id = $1 AND users.id NOT IN " \
          "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = $2)"
    got, rewrite = verdicts_of(rules::NotInToNotExists.new, sql)

    expect(rewrite).to include("NOT EXISTS").and include("memberships.group_id = $2")
    expect(got).to eq("users.account_id = $1" => true,
                      "users.id IN (SELECT memberships.user_id FROM public.memberships WHERE " \
                      "memberships.group_id = $2)" => false,
                      "memberships.group_id = $2" => false)
  end

  it "calls every atom changed when existence_in_flip makes another table drive" do
    sql = "SELECT 1 AS one FROM public.enrollments JOIN public.courses ON courses.id = enrollments.course_id " \
          "JOIN public.assignments ON assignments.context_id = courses.id " \
          "WHERE enrollments.user_id = 10 AND courses.workflow_state <> 'deleted' AND assignments.id IN " \
          "(SELECT tool_lookups.assignment_id FROM public.tool_lookups WHERE tool_lookups.tool_product_code = 'x') " \
          "LIMIT 1"
    got, rewrite = verdicts_of(rules::ExistenceInFlip.new, sql, literals: true)

    expect(rewrite).to include("EXISTS").and include("enrollments.user_id = $2")
    expect(got.size).to be >= 5
    expect(got.values).to all(be(false))
  end

  it "calls the equalities implied_predicate_removal kept unchanged, and the predicates it removed changed" do
    sql = "SELECT enrollments.id FROM public.enrollments WHERE enrollments.workflow_state <> 'deleted' AND " \
          "enrollments.workflow_state = 'active' AND enrollments.type IN ('StudentEnrollment', " \
          "'TeacherEnrollment') AND enrollments.type = 'TeacherEnrollment'"
    got, rewrite = verdicts_of(rules::ImpliedPredicateRemoval.new, sql, literals: true)

    expect(rewrite).to eq("SELECT enrollments.id FROM public.enrollments WHERE " \
                          "enrollments.workflow_state = $2 AND enrollments.type = $5")
    expect(got).to eq("enrollments.workflow_state <> $1" => false, "enrollments.workflow_state = $2" => true,
                      "enrollments.type IN ($3, $4)" => false, "enrollments.type = $5" => true)
  end

  it "calls a predicate changed when implied_predicate_removal drops one of its duplicates" do
    sql = "SELECT enrollments.id FROM public.enrollments WHERE enrollments.score >= 10 AND " \
          "enrollments.score BETWEEN 10 AND 20 AND enrollments.score = 15 AND enrollments.score IS NOT NULL AND " \
          "enrollments.score IS NOT NULL"
    got, rewrite = verdicts_of(rules::ImpliedPredicateRemoval.new, sql, literals: true)

    expect(rewrite).to eq("SELECT enrollments.id FROM public.enrollments WHERE enrollments.score = $4 AND " \
                          "enrollments.score IS NOT NULL")
    expect(got).to eq("enrollments.score >= $1" => false, "enrollments.score BETWEEN $2 AND $3" => false,
                      "enrollments.score = $4" => true, "enrollments.score IS NOT NULL" => false)
  end

  it "calls the filter transitive_predicate_copy copied from changed, though the rewrite keeps its text" do
    sql = "SELECT enrollments.id FROM public.enrollments JOIN public.courses ON enrollments.course_id = courses.id " \
          "WHERE courses.id IN (2, 3) AND enrollments.user_id = 10"
    got, rewrite = verdicts_of(rules::TransitivePredicateCopy.new, sql, literals: true)

    expect(rewrite).to include("courses.id IN ($1, $2)").and include("enrollments.course_id IN ($1, $2)")
    expect(got).to include("courses.id IN ($1, $2)" => false, "enrollments.user_id = $3" => true)
  end

  describe "an LLM-style rewrite, which no rule wrote" do
    def prepared?(sql)
      conn.prepare("quaack_llm_check", sql)
      conn.exec("DEALLOCATE quaack_llm_check")
      true
    end

    it "calls every atom changed when it reuses an alias for another table" do
      original = "SELECT e.id FROM public.courses e WHERE e.workflow_state = $1 AND e.id > $2"
      candidate = "SELECT e.id FROM public.assignments e WHERE e.workflow_state = $1 AND e.id > $2"

      expect([original, candidate].all? { prepared?(it) }).to be(true)
      expect(verdicts(original, candidate)).to eq("e.workflow_state = $1" => false, "e.id > $2" => false)
    end

    it "calls an atom unchanged when the rewrite only changed another predicate of the same table" do
      original = "SELECT e.id FROM public.courses e WHERE e.workflow_state = $1 AND e.id > $2"
      candidate = "SELECT e.id FROM public.courses e WHERE e.workflow_state = $1 AND e.id >= $2"

      expect([original, candidate].all? { prepared?(it) }).to be(true)
      expect(verdicts(original, candidate)).to eq("e.workflow_state = $1" => true, "e.id > $2" => false)
    end
  end
end
