# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/literals"
require "quaack/enclave/rewrite_rules/polymorphic_key_copy"
require_relative "support/production_server"

# DESIGN.md 6c's polymorphic_key_copy, on a real server, in Canvas's shape:
# a submission joins its assignment, whose context is a Rails polymorphic
# pair, and the submission keeps its own copy of the course id. The rule
# adds that copy's filter, reusing the id's placeholder, and states the
# assumption 6b checks against the data.
RSpec.describe Quaack::Enclave::RewriteRules::PolymorphicKeyCopy do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.courses (id bigint PRIMARY KEY);
      CREATE TABLE public.users (id bigint PRIMARY KEY);
      CREATE TABLE public.statuses (id bigint PRIMARY KEY);
      CREATE TABLE public.assignments (id bigint PRIMARY KEY, context_type varchar(255), context_id bigint,
                                       owner_type varchar(255), owner_id bigint);
      CREATE TABLE public.submissions (
        id bigint PRIMARY KEY, assignment_id bigint, course_id bigint REFERENCES public.courses,
        user_id bigint, group_id bigint REFERENCES public.courses, status_id bigint REFERENCES public.statuses,
        foo_bar_id bigint
      );
      INSERT INTO public.courses VALUES (1), (2);
      INSERT INTO public.users VALUES (100), (101);
      INSERT INTO public.statuses VALUES (7);
      INSERT INTO public.assignments VALUES
        (1, 'Course', 1, 'User', 100), (2, 'Course', 2, 'User', 101), (3, 'Foo::Bar', 5, NULL, NULL),
        (4, 'Status', 7, NULL, NULL);
      INSERT INTO public.submissions VALUES
        (1, 1, 1, 100, NULL, NULL, NULL), (2, 2, 2, 100, NULL, NULL, NULL), (3, 1, 1, 101, NULL, NULL, NULL),
        (4, 3, NULL, 100, NULL, NULL, 5), (5, 4, NULL, 100, NULL, 7, NULL);
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  def literals_for(sql)
    redacted = redacted(sql)
    [redacted.sql,
     Quaack::Enclave::RewriteRules::Literals.new(conn, redacted.placeholder_map, redacted.placeholder_shapes)]
  end

  def rewrites(sql)
    redacted, literals = literals_for(sql)
    rule.rewrites(PgQuery.parse(redacted), catalog, literals)
  end

  def rewritten(sql) = rewrites(sql).map { Quaack::Enclave::Deparse.faithfully(it.tree) }

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

  def assumption(column, type_value, type: "context_type", id: "context_id")
    { "kind" => "denormalized_equal", "table" => "public.submissions", "column" => column,
      "join_column" => "assignment_id", "references_table" => "public.assignments", "references_column" => "id",
      "type_column" => type, "type_value" => type_value, "id_column" => id }
  end

  let(:canvas) do
    "SELECT submissions.id FROM public.submissions JOIN public.assignments " \
      "ON assignments.id = submissions.assignment_id " \
      "WHERE assignments.context_type = 'Course' AND assignments.context_id = 1 AND submissions.user_id = 100"
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["polymorphic_key_copy",
       "Where a joined parent is filtered to one Rails polymorphic type and id, the child's own column for " \
       "that type is filtered to the same id."]
    )
  end

  it "adds the child's copy of a polymorphic id, reusing its placeholder, in Canvas's shape" do
    expect_rewrite(
      canvas,
      "SELECT submissions.id FROM public.submissions JOIN public.assignments " \
      "ON assignments.id = submissions.assignment_id " \
      "WHERE assignments.context_type = $1 AND assignments.context_id = $2 AND submissions.user_id = $3 " \
      "AND submissions.course_id = $2"
    )
  end

  it "states the denormalized_equal assumption 6b checks against the data" do
    expect(rewrites(canvas).map(&:assumptions)).to eq([[assumption("course_id", "Course")]])
  end

  it "matches under aliases, with the join and filters in the WHERE either way round" do
    expect_rewrite(
      "SELECT s.id FROM public.submissions s, public.assignments a WHERE s.assignment_id = a.id " \
      "AND 'Course' = a.context_type AND 1 = a.context_id",
      "SELECT s.id FROM public.submissions s, public.assignments a WHERE s.assignment_id = a.id " \
      "AND $1 = a.context_type AND $2 = a.context_id AND s.course_id = $2"
    )
  end

  it "names a namespaced class's column with :: as _, so Foo::Bar is foo_bar_id" do
    sql = canvas.sub("'Course'", "'Foo::Bar'").sub("context_id = 1", "context_id = 5")
    expect_rewrite(sql, "#{redacted(sql).sql} AND submissions.foo_bar_id = $2")
    expect(rewrites(sql).map(&:assumptions)).to eq([[assumption("foo_bar_id", "Foo::Bar")]])
  end

  it "names a CamelCase class's column in snake_case, so FooBar is foo_bar_id too" do
    sql = canvas.sub("'Course'", "'FooBar'")
    expect(rewrites(sql).map(&:assumptions)).to eq([[assumption("foo_bar_id", "FooBar")]])
  end

  it "fires when the column's foreign key points at the class's table, plural with es" do
    sql = canvas.sub("'Course'", "'Status'").sub("context_id = 1", "context_id = 7")
    expect_rewrite(sql, "#{redacted(sql).sql} AND submissions.status_id = $2")
  end

  it "doesn't fire when the column's foreign key points at another table" do
    expect(rewritten(canvas.sub("'Course'", "'Group'"))).to eq([])
  end

  it "doesn't fire when the type names no column of the child, or the class isn't written Rails's way" do
    expect([rewritten(canvas.sub("'Course'", "'Account'")), rewritten(canvas.sub("'Course'", "'course'")),
            rewritten(canvas.sub("'Course'", "'Foo_Bar'"))]).to eq([[], [], []])
  end

  it "refuses when two columns of the child could match" do
    sql = "#{canvas} AND assignments.owner_type = 'User' AND assignments.owner_id = 100"
    expect(rewritten(sql)).to eq([])
  end

  it "doesn't fire on an outer join's nullable side" do
    expect(rewritten(canvas.sub("JOIN public.assignments", "LEFT JOIN public.assignments"))).to eq([])
  end

  it "doesn't fire without the id filter, or with a cast on its constant" do
    expect([rewritten(canvas.sub(" AND assignments.context_id = 1", "")),
            rewritten(canvas.sub("context_id = 1", "context_id = 1::bigint"))]).to eq([[], []])
  end

  it "doesn't add the copy again when the query already has it" do
    redacted_sql, literals = literals_for(canvas)
    once = rule.rewrites(PgQuery.parse(redacted_sql), catalog, literals).first.tree
    again = rule.rewrites(Quaack::Enclave::Deparse.faithful_parse(once), catalog, literals)
    expect(again).to eq([])
  end

  it "does nothing without a literal oracle" do
    expect(rule.rewrites(PgQuery.parse(redacted(canvas).sql), catalog, nil)).to eq([])
  end

  it "is part of RULES and gives the generator its rewrite, with its assumption" do
    redacted_sql, literals = literals_for(canvas)
    generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(redacted_sql), catalog, literals)
    mine = generated.rewrites.find { it.rules.map(&:name) == ["polymorphic_key_copy"] }
    expect(mine&.assumptions).to eq([assumption("course_id", "Course")])
  end
end
