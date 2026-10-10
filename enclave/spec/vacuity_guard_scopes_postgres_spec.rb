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
      CREATE TABLE fx.submissions (id bigint PRIMARY KEY, assignment_id bigint NOT NULL REFERENCES fx.assignments,
        user_id bigint NOT NULL, workflow_state text NOT NULL, cached_due_date timestamp);
      CREATE TABLE fx.content_participations (id bigint PRIMARY KEY, content_type text NOT NULL,
        content_id bigint NOT NULL, user_id bigint NOT NULL, workflow_state text NOT NULL);
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

  def ids(count, base) = (1..count).map { base + it }.join(", ")

  def branch(extra)
    "fx.assignments.type = 'Assignment' AND fx.assignments.workflow_state <> 'deleted' " \
      "AND fx.assignments.context_type = 'Course' " \
      "AND fx.assignments.context_id IN (#{ids(21, 100)}) #{extra}"
  end

  # The shape of a real count query: an IN subquery whose two UNION ALL
  # branches repeat four tests on assignments, and whose second branch pins
  # assignments.id, the key submissions join on, to 12 values.
  def count_subquery
    "SELECT fx.assignments.id FROM fx.assignments JOIN fx.submissions " \
      "ON fx.submissions.assignment_id = fx.assignments.id AND fx.submissions.workflow_state <> 'deleted' " \
      "JOIN fx.content_participations ON fx.content_participations.content_type = 'Submission' " \
      "AND fx.content_participations.content_id = fx.submissions.id WHERE " \
      "#{branch("AND (fx.assignments.muted IS NULL OR NOT fx.assignments.muted)")} " \
      "AND fx.content_participations.user_id = 7 AND fx.content_participations.workflow_state = 'unread' " \
      "UNION ALL SELECT fx.assignments.id FROM fx.assignments " \
      "WHERE #{branch("AND fx.assignments.id IN (#{ids(12, 500)})")}"
  end

  def count_query
    "SELECT count(*) FROM fx.assignments JOIN fx.submissions " \
      "ON fx.submissions.assignment_id = fx.assignments.id AND fx.submissions.workflow_state <> 'deleted' " \
      "WHERE fx.assignments.type = 'Assignment' " \
      "AND fx.assignments.id IN (#{count_subquery}) AND fx.submissions.user_id = 7 " \
      "AND fx.submissions.workflow_state <> 'deleted' " \
      "AND fx.submissions.cached_due_date BETWEEN '2026-01-01' AND '2026-02-01'"
  end

  # Each branch's own copies of the repeated tests, and the subquery as a
  # whole, are tested.
  it "tests the repeated branch atoms of a UNION ALL subquery under a count" do
    tested = [
      "fx.assignments.workflow_state <> $6", "fx.assignments.context_type = $7",
      "fx.assignments.workflow_state <> $32", "fx.assignments.context_type = $33"
    ]
    found = untested(count_query)
    expect(found & tested).to eq([])
    expect(found.grep(/\Afx\.assignments\.id IN \(SELECT/)).to eq([])
  end

  # Each group takes its own generated key where that fits (a near miss of
  # the list, or a masking near miss that fails the list), or else a list
  # value of its own, so the groups don't all take the first one and
  # collide on the primary key (20261010-21). What stays untested is
  # redundant: submissions.workflow_state <> $1 and <> $68 test the same
  # row the same way, and the three type tests each imply the others
  # through the subquery. The branch's submissions.workflow_state <> $3 is
  # tested by a sibling: a second submission under the masking near miss's
  # assignment, which the outer query counts (20261010-24).
  it "tests every atom of the count query but the redundant ones" do
    redundant = [
      "fx.submissions.workflow_state <> $1", "fx.submissions.workflow_state <> $68",
      "fx.assignments.type = $2", "fx.assignments.type = $5", "fx.assignments.type = $31"
    ]
    expect(untested(count_query) - redundant).to eq([])
  end
end
