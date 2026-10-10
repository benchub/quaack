# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"
require "quaack/enclave/vacuity_guard"

# vacuity-guard across scopes and branches (20261010-19). A near miss fails
# its atom in its own scope only, so the same test on the same column in
# another scope (a subquery, a UNION branch) doesn't stop it being built.
RSpec.describe Quaack::Enclave::VacuityGuard do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.assignments (id bigint PRIMARY KEY, type text NOT NULL, workflow_state text NOT NULL,
        context_type text NOT NULL, context_id bigint NOT NULL, muted boolean);
    SQL
  end

  def untested(sql)
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    described_class.run(runner, builder, sql).untested
  end

  it "tests one column's same atom in two UNION ALL branches, each on its own" do
    sql = "SELECT count(*) FROM fx.assignments WHERE fx.assignments.id IN (" \
          "SELECT fx.assignments.id FROM fx.assignments WHERE fx.assignments.workflow_state <> 'deleted' " \
          "UNION ALL SELECT fx.assignments.id FROM fx.assignments WHERE fx.assignments.workflow_state <> 'deleted')"
    expect(untested(sql)).to eq([])
  end

  # The hit passes every branch, so a near miss that fails one atom of one
  # branch still passes the others. A masking near miss fails an atom in
  # each other branch too.
  it "tests an atom of one UNION ALL branch that the other branch would let through" do
    sql = "SELECT count(*) FROM fx.assignments WHERE fx.assignments.id IN (" \
          "SELECT fx.assignments.id FROM fx.assignments WHERE fx.assignments.context_type = 'Course' " \
          "UNION ALL SELECT fx.assignments.id FROM fx.assignments WHERE fx.assignments.workflow_state <> 'deleted')"
    expect(untested(sql)).to eq([])
  end

  it "tests each arm of an OR, failing the other arm with it" do
    sql = "SELECT count(*) FROM fx.assignments WHERE fx.assignments.context_type = 'Course' " \
          "OR fx.assignments.workflow_state <> 'deleted'"
    expect(untested(sql)).to eq([])
  end

  it "reads a NOT arm of an OR as failed when its atom holds" do
    sql = "SELECT count(*) FROM fx.assignments WHERE fx.assignments.context_type = 'Course' " \
          "AND (fx.assignments.muted IS NULL OR NOT fx.assignments.muted)"
    expect(untested(sql)).to eq([])
  end
end
