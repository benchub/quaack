# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/denormalized_fixture"
require "quaack/enclave/step_nine"
require "quaack/enclave/table_name"

# Arena fixtures that honour a rule's denormalized_equal assumption (DESIGN.md
# 6c, 9, 10a), in Canvas's shape: a submission of an assignment whose
# context is a Course keeps a copy of the course id, which a foreign key
# checks.
RSpec.describe "Arena fixtures honouring a denormalized_equal assumption" do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:copy) do
    Quaack::Enclave::DenormalizedFixture::Copy.new(
      table: table("submissions"), column: "course_id", join_column: "assignment_id",
      references_table: table("assignments"), references_column: "id", type_column: "context_type",
      type_value: "Course", id_column: "context_id"
    )
  end

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA cv;
      CREATE TABLE cv.courses (id bigint PRIMARY KEY);
      CREATE TABLE cv.assignments (id bigint PRIMARY KEY, context_type text NOT NULL, context_id bigint NOT NULL);
      CREATE TABLE cv.submissions (id bigint PRIMARY KEY, assignment_id bigint REFERENCES cv.assignments,
                                   course_id bigint REFERENCES cv.courses, body text);
    SQL
  end

  def table(name) = Quaack::Enclave::TableName.new(schema: "cv", name:)

  def row(name, values)
    Quaack::Enclave::ArenaRunner::FixtureRow.new(table: table(name), columns: values.keys,
                                                 values: values.values.map { it&.to_s })
  end

  # Assignment 1 is a Course's and assignment 2 an Account's, both with
  # context 50; each submission keeps course 1.
  let(:rows) do
    [row("courses", { "id" => 1 }),
     row("assignments", { "id" => 1, "context_type" => "Course", "context_id" => 50 }),
     row("assignments", { "id" => 2, "context_type" => "Account", "context_id" => 50 }),
     row("submissions", { "id" => 1, "assignment_id" => 1, "course_id" => 1 }),
     row("submissions", { "id" => 2, "assignment_id" => 2, "course_id" => 1 }),
     row("submissions", { "id" => 3, "assignment_id" => 1, "course_id" => nil })]
  end

  def copies(runner)
    runner.with_fixture(rows) do |fixture|
      fixture.query("SELECT id, course_id FROM cv.submissions ORDER BY id").rows
    end
  end

  def foreign_keys
    conn.exec("SELECT count(*) FROM pg_constraint WHERE conrelid = 'cv.submissions'::regclass AND contype = 'f'")
        .getvalue(0, 0).to_i
  end

  describe Quaack::Enclave::DenormalizedFixture::Runner do
    it "sets the copy on the class's rows only, in spite of the copy's foreign key, and rolls it all back" do
      honoured = copies(described_class.new(conn, [copy]))

      expect(honoured).to eq([%w[1 50], %w[2 1], %w[3 50]])
      expect(foreign_keys).to eq(2)
      expect(conn.exec("SELECT count(*) FROM cv.submissions").getvalue(0, 0)).to eq("0")
    end

    it "leaves the fixture as built without a copy to honour" do
      expect(copies(described_class.new(conn, []))).to eq([%w[1 1], %w[2 1], ["3", nil]])
    end

    it "refuses copies that aren't Copies" do
      expect { described_class.new(conn, [{ "kind" => "denormalized_equal" }]) }
        .to raise_error(ArgumentError, /copies must be/)
    end

    it "is an ArenaRunner, with its statement timeout" do
      runner = described_class.new(conn, [copy], statement_timeout_ms: 1)
      expect { runner.with_fixture(rows) { it.query("SELECT pg_sleep(1)") } }
        .to raise_error(Quaack::Enclave::ArenaRunner::Error) { expect(it.rule).to eq(:statement_timeout) }
    end
  end

  describe Quaack::Enclave::StepNine do
    let(:original) do
      "SELECT s.id FROM cv.submissions s JOIN cv.assignments a ON a.id = s.assignment_id " \
        "WHERE a.context_type = 'Course' AND a.context_id = 50 AND s.body = 'SENTINEL_77'"
    end
    let(:rewritten) { original.sub("AND s.body", "AND s.course_id = 50 AND s.body") }

    def run(*candidates, honour: [copy])
      Quaack::Enclave::StepNine.run(conn, original, candidates, honour:).results.map { [it.passed, it.scenario] }
    end

    it "passes the rule's rewrite on fixtures that honour its assumption, and disproves wrong twins" do
      expect(run(rewritten, rewritten.sub("s.course_id = 50", "s.course_id = 51")).map(&:first)).to eq([true, false])
    end

    it "disproves the same rewrite on fixtures that don't honour the assumption" do
      expect(run(rewritten, honour: []).first.first).to be(false)
    end
  end
end
