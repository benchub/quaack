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
end
