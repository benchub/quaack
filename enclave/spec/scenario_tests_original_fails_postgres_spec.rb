# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"
require "quaack/enclave/scenario_tests"
require "quaack/enclave/vacuity_guard"

# Task 20261012-11: a fixture on which the original query fails, by an
# error from the data (a division by a points_possible of 0, say), says
# nothing about a rewrite, the way a fixture that won't load says nothing.
# vacuity-guard counts it as exercising nothing, and rewrite-test skips it
# for comparison, testing the rewrite on the other fixtures. A candidate
# compared on no fixture at all doesn't pass.
RSpec.describe Quaack::Enclave::ScenarioTests do
  let(:conn) { racetrack_and_arena.arena.connection }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.assignments (id bigint PRIMARY KEY, points_possible numeric);
      CREATE TABLE fx.submissions (id bigint PRIMARY KEY,
        assignment_id bigint NOT NULL REFERENCES fx.assignments, course_id bigint, score numeric);
    SQL
  end

  let(:from) { "FROM fx.submissions s JOIN fx.assignments a ON a.id = s.assignment_id" }
  let(:ratio) { "SELECT s.id #{from} WHERE s.course_id = 1 AND (s.score / a.points_possible) >= 0.9" }

  def run(sql, *candidates, search: true) = described_class.run(conn, sql, candidates, search:)

  def outcomes(report) = report.results.map { [it.passed, it.scenario, it.rule] }

  it "has scenarios whose rows make the original divide by zero" do
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(ratio))
    runner = Quaack::Enclave::ArenaRunner.new(conn)
    error = begin
      runner.with_fixture(builder.build[:s1]) { |tx| tx.query(ratio) }
    rescue Quaack::Enclave::ArenaRunner::Error => e
      e
    end
    expect([error.rule, error.step, error.sqlstate]).to eq([:query_failed, :query, "22012"])
  end

  it "tests the query with no candidates without crashing, and leaves the atoms S1 can't run untested" do
    report = run(ratio, search: false)

    expect(report.results).to eq([])
    expect(report.untested).to eq(["a.id = s.assignment_id", "s.course_id = $1", "(s.score / a.points_possible) >= $2"])
    expect(report.s1_load_rule).to eq(:original_failed)
    expect([report.s1_rows, report.s1_nonzero_rows]).to eq([nil, nil])
    expect(report.retries).to eq(3 * 3)
  end

  # vacuity-guard's search finds small databases where the original runs
  # and each atom shows, and they join S1, so rewrite-test still tests the
  # rewrites there.
  it "passes an equivalent candidate and disproves wrong ones on the fixtures the original runs on" do
    report = run(ratio, "SELECT s.id #{from} WHERE (s.score / a.points_possible) >= 0.9 AND s.course_id = 1",
                 "SELECT s.id #{from} WHERE (s.score / a.points_possible) >= 0.9",
                 # Wrong for a negative points_possible (corpus case cv_score_ratio).
                 "SELECT s.id #{from} WHERE s.course_id = 1 AND s.score >= 0.9 * a.points_possible")

    expect(outcomes(report)).to eq([[true, nil, nil], [false, :s1, :row_count], [false, :s1, :row_count]])
    expect(report.untested).to eq([])
    expect(report.s1_load_rule).to eq(:original_failed)
  end

  it "still disproves a candidate that fails where the original runs, with the runner's rule" do
    multiplied = "SELECT s.id #{from} WHERE s.course_id = 1 AND s.score >= 0.9 * a.points_possible"

    report = run(multiplied, ratio)

    expect(outcomes(report)).to eq([[false, :s1, :query_failed]])
  end

  # S1's near miss for points_possible <> 0 holds a 0, so with that atom
  # replaced by TRUE, the division fails.
  it "counts an atom whose loosened query fails as not exercised there, and the others as usual" do
    guarded = "SELECT s.id #{from} WHERE s.course_id = 1 AND a.points_possible <> 0 " \
              "AND (s.score / a.points_possible) >= 0.9"

    report = run(guarded, search: false)

    expect(report.untested).to eq(["a.points_possible <> $2"])
    expect([report.retries, report.s1_load_rule]).to eq([3, nil])
    # One S1 load an attempt: the loads again without the failing atom
    # aren't counted, since whether it fails follows the data.
    expect(report.loads).to eq(4)
  end

  # A LIMIT with no ORDER BY gives S1 a further fixture of its near misses
  # alone (Scenarios::Plan#near_misses_alone). With every points_possible 0,
  # the near miss for a.id + 0 > 5 reaches the division there too.
  it "reads a further S1 fixture the original fails on as exercising nothing" do
    conn.exec("ALTER TABLE fx.assignments ADD CHECK (points_possible = 0)")
    sql = "SELECT a.id FROM fx.assignments a WHERE (10 / a.points_possible) >= 1 AND a.id + 0 > 5 LIMIT 10"
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    builder.build
    spill = builder.spills.fetch(:s1)
    expect { Quaack::Enclave::ArenaRunner.new(conn).with_fixture(spill.first) { |tx| tx.query(sql) } }
      .to raise_error(Quaack::Enclave::ArenaRunner::Error) { |e| expect(e.sqlstate).to eq("22012") }

    report = run(sql, search: false)

    expect(report.untested).to eq(["($1 / a.points_possible) >= $2", "(a.id + $3) > $4"])
    expect(report.s1_load_rule).to eq(:original_failed)
  end

  # The share of course 1's submissions scored 90% or more: count(*) is 0
  # on S0's empty tables, and every other scenario holds a points_possible
  # of 0, so the original fails on every fixture.
  # Task 20261012-11, review: S0's tables are empty, so a plain SELECT
  # compares nothing there. With the search off (search: false stands in
  # for a LIMIT, a volatile function, or a count threshold), the original
  # fails on every fixture with rows, so only S0 ran.
  describe "an original that runs only on fixtures with no rows" do
    let(:wrong) do
      ["SELECT s.id #{from} WHERE s.course_id = 2 AND (s.score / a.points_possible) >= 0.9",
       "SELECT s.id #{from} WHERE (s.score / a.points_possible) >= 0.9",
       "#{ratio} ORDER BY s.id DESC LIMIT 5", "#{ratio} LIMIT 4"]
    end

    it "doesn't pass a wrong candidate, or an equivalent one, with original_failed and no scenario" do
      equivalent = "SELECT s.id #{from} WHERE (s.score / a.points_possible) >= 0.9 AND s.course_id = 1"

      report = run(ratio, *wrong, equivalent, search: false)

      expect(outcomes(report)).to eq([[false, nil, :original_failed]] * 5)
    end

    it "still disproves a candidate that differs on the empty tables" do
      total = "SELECT sum(s.score / a.points_possible) AS total #{from} WHERE s.course_id = 1"
      coalesced = "SELECT coalesce(sum(s.score / a.points_possible), 0) AS total #{from} WHERE s.course_id = 1"

      expect(outcomes(run(total, coalesced, search: false))).to eq([[false, :s0, :multiset]])
    end
  end

  describe "an original that fails on every fixture" do
    let(:share) do
      "SELECT 100 * count(*) FILTER (WHERE (s.score / a.points_possible) >= 0.9) / count(*) AS share " \
        "#{from} WHERE s.course_id = 1"
    end

    it "doesn't pass a candidate compared on nothing, with original_failed and no scenario" do
      report = run(share, "SELECT 100 * count(*) FILTER (WHERE s.score >= 0.9 * a.points_possible) / count(*) " \
                          "AS share #{from} WHERE s.course_id = 1", search: false)

      expect(outcomes(report)).to eq([[false, nil, :original_failed]])
      expect(report.results.first.load_order).to be_nil
    end

    it "runs the original again on a fixture once a run, not once a candidate" do
      candidate = "SELECT 100 * count(*) FILTER (WHERE s.score >= 0.9 * a.points_possible) / count(*) " \
                  "AS share #{from} WHERE s.course_id = 1"

      one = run(share, candidate, search: false)
      two = run(share, candidate, candidate, search: false)

      expect(outcomes(two)).to eq([[false, nil, :original_failed]] * 2)
      expect(two.loads).to eq(one.loads)
    end
  end

  # The arena's edge: every query is canceled, as by an operator.
  it "raises a cancel QUAACK didn't send, without running the original again to ask why" do
    loads = 0
    canceling = Class.new(SimpleDelegator) do
      define_method(:with_fixture) do |*, **|
        loads += 1
        raise Quaack::Enclave::ArenaRunner::Error.new(:statement_canceled, step: :query, sqlstate: "57014", index: 0),
              cause: nil
      end
    end.new(Quaack::Enclave::ArenaRunner.new(conn))
    fixtures = described_class.fixtures(Quaack::Enclave::Scenarios::NAMES.to_h { [it, []] }, {})

    expect { described_class.test(canceling, fixtures, ratio, ratio) }
      .to raise_error(Quaack::Enclave::ArenaRunner::Error) { |e| expect(e.rule).to eq(:statement_canceled) }
    expect(loads).to eq(1)
  end
end
