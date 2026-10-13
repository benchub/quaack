# frozen_string_literal: true

require "pg_query"
require_relative "arena_runner"
require_relative "denormalized_fixture"
require_relative "result_comparison"
require_relative "result_comparison/original_rerun"
require_relative "scenarios"
require_relative "vacuity_guard"

module Quaack
  module Enclave
    # rewrite-test, end to end, for one query and its candidates.
    #
    #   report = ScenarioTests.run(arena_connection, original_sql, [candidate_sql, ...])
    #   report.results  # => [Result(passed: true, scenario: nil, ...), Result(passed: false, scenario: :s2, ...)]
    #   report.untested # => vacuity-guard's untested atoms, by redacted shape
    #
    # It builds the scenarios (Scenarios), runs vacuity-guard on S1
    # (VacuityGuard), and then, for each candidate in order, runs S0
    # through S6 through fixture-compare's comparison (ResultComparison.
    # compare_in_load_orders), each in its own arena transactions that roll
    # back. The first scenario that doesn't match disproves the candidate,
    # and the rest don't run. Its Result names the scenario, the verdict's
    # rule (such as :multiset, or :unsupported_order for a refusal) and
    # load order. A candidate that fails in arena doesn't pass either: its
    # Result has the runner's rule (such as :query_failed) and no load order,
    # and RewriteFate counts that as a runner failure, not a disproof. A query
    # that fails with statement_canceled, a cancel QUAACK didn't send, is
    # raised instead, and ends the step with no verdict, as in RunDiscipline
    # (ArenaRunner::Cancel.foreign?). A candidate
    # that matches every scenario passes, with scenario nil.
    #
    # A fixture on which the original itself fails (a division by a column
    # that's 0 there, say) says nothing about a candidate, like one that
    # won't load. When a comparison fails other than by a cancel QUAACK
    # didn't send, ResultComparison::OriginalRerun says whether the
    # original failed there. If it did, the fixture is skipped, for this
    # candidate and the later ones, and the rest run. A fixture with no
    # rows at all (S0) still runs and can disprove, but doesn't count as
    # compared: a plain SELECT compares nothing on empty tables. A
    # candidate compared on no fixture with rows doesn't pass: its Result
    # has the rule :original_failed and scenario nil, a runner failure to
    # RewriteFate.
    #
    # honour is the DenormalizedFixture::Copies of a rule's rewrite under
    # test. Every fixture, the guard's included, then keeps each copy on
    # the class's rows. rewrite-test and counterexamples test one rewrite at a time, so the
    # copies are its own.
    #
    # When the scenarios can't be built for the query (a Scenarios::Error,
    # such as fk_cycle or complex_check), no candidate is tested. The
    # report's refused is then the error's rule, and every candidate's
    # Result is not passed, with that rule and scenario nil. Otherwise
    # refused is nil. For fk_cycle, cycle is the cycle's TableNames
    # (Scenarios::Topology); otherwise it's nil.
    #
    # Trust boundary: the report holds booleans, symbols, counts, and vacuity-guard's
    # redacted shapes. The fixtures, with the real literals, stay here. A
    # refusal keeps only its rule, never the column it names, and for
    # fk_cycle the cycle's table names, which are schema.
    module ScenarioTests
      # dropped counts the scenario groups left out because they collide on
      # a unique key (Scenarios::Builder#dropped). loads counts the fixtures
      # loaded in arena (ArenaRunner#loads), the guard's included. s1_load_rule
      # s1_rows and s1_nonzero_rows are vacuity-guard's diagnostic
      # (VacuityGuard::Result): the rule S1 failed to load with (or
      # :original_failed when the original failed on S1's rows), the
      # original's row count on S1, and how many of those rows are nonzero, each
      # nil when it doesn't apply (and both nil on a refusal).
      # untested_paths are the untested atoms' paths into the original's parse
      # (PredicateAtoms::Atom#path), for AtomPosition; they stay in the enclave.
      # untested_states says, per untested atom, how it stayed unproven
      # (VacuityGuard::Search's state words).
      Report = Data.define(:results, :untested, :untested_atoms, :untested_paths, :retries, :dropped, :refused,
                           :cycle, :loads, :s1_load_rule, :s1_rows, :s1_nonzero_rows, :untested_states) do
        def initialize(untested_paths: [], untested_states: [], **fields) = super
      end
      Result = Data.define(:passed, :scenario, :rule, :load_order)

      module_function

      # search: false leaves out vacuity-guard's search (VacuityGuard::Search),
      # for a spec of the rule-based scenarios alone.
      def run(conn, sql, candidates, statement_timeout_ms: 10_000, honour: [], search: true) # rubocop:disable Metrics/ParameterLists
        runner = DenormalizedFixture::Runner.new(conn, honour, statement_timeout_ms:)
        builder = Scenarios::Builder.new(conn, PgQuery.parse(sql))
        guard = VacuityGuard.run(runner, builder, sql, search:)
        fixtures = fixtures(guard.scenarios, builder.spills)
        results = candidates.map { |candidate| test(runner, fixtures, sql, candidate) }
        tested(guard, builder, results, runner.loads)
      rescue Scenarios::Error => e
        refused(candidates, e.rule, cycle: e.cycle, loads: runner.loads)
      end

      # The report of candidates tested on the guard's scenarios.
      def tested(guard, builder, results, loads)
        Report.new(results:, untested: guard.untested, untested_atoms: guard.untested_atoms,
                   untested_paths: guard.untested_paths, untested_states: guard.untested_states,
                   retries: guard.retries,
                   dropped: builder.dropped, refused: nil, cycle: nil, loads:, s1_load_rule: guard.s1_load_rule,
                   s1_rows: guard.s1_rows, s1_nonzero_rows: guard.s1_nonzero_rows)
      end

      def refused(candidates, rule, cycle: nil, loads: 0)
        results = candidates.map { Result.new(passed: false, scenario: nil, rule:, load_order: nil) }
        Report.new(results:, untested: [], untested_atoms: [], retries: 0, dropped: 0, refused: rule,
                   cycle: (cycle if rule == :fk_cycle), loads:, s1_load_rule: nil, s1_rows: nil,
                   s1_nonzero_rows: nil)
      end

      # A fixture to compare on, named for its scenario. skipped is set once
      # the original fails on it, for every candidate after.
      Fixture = Struct.new(:name, :rows, :skipped)

      # Every scenario's fixtures, S0 to S6: its first, then its further
      # ones (spills, see Scenarios::Parts), under its name.
      def fixtures(scenarios, spills)
        Scenarios::NAMES.flat_map do |name|
          [scenarios.fetch(name), *spills.fetch(name, [])].map { Fixture.new(name, it, false) }
        end
      end

      # The first fixture's Result that doesn't pass, else PASSED, or
      # ORIGINAL_FAILED when every fixture with rows is skipped. A fixture
      # with no rows (S0's empty tables) runs, and can disprove, but a
      # plain SELECT compares nothing there, so it doesn't count.
      def test(runner, fixtures, sql, candidate)
        fixtures.each do |fixture|
          result = compared(runner, fixture, sql, candidate) unless fixture.skipped
          return result if result && !result.passed
        end
        fixtures.all? { it.skipped || it.rows.empty? } ? ORIGINAL_FAILED : PASSED
      end

      PASSED = Result.new(passed: true, scenario: nil, rule: nil, load_order: nil)

      # A candidate the original failed on every fixture with rows for was
      # compared on nothing, so it doesn't pass.
      ORIGINAL_FAILED = Result.new(passed: false, scenario: nil, rule: :original_failed, load_order: nil)

      # The candidate's Result on fixture, or nil when the original fails
      # there, which skips it.
      def compared(runner, fixture, sql, candidate)
        verdict = ResultComparison.compare_in_load_orders(runner, fixture.rows, original: sql, candidate:)
        return PASSED if verdict.match?

        Result.new(passed: false, scenario: fixture.name, rule: verdict.rule, load_order: verdict.load_order)
      rescue ArenaRunner::Error => e
        return failed(fixture.name, e) unless original_failed?(runner, fixture.rows, sql, e)

        fixture.skipped = true
        nil
      end

      # Whether error, from a comparison on rows, came from the original
      # failing there (ResultComparison::OriginalRerun), not from a load or
      # the candidate: a fixture that won't load fails the rerun's load too,
      # which says no. A cancel QUAACK didn't send goes up.
      def original_failed?(runner, rows, sql, error)
        raise error if ArenaRunner::Cancel.foreign?(error)

        ResultComparison::OriginalRerun.fails?(runner, rows, sql)
      end

      # A runner failure in scenario name: a Result, or the error itself,
      # raised, for a cancel QUAACK didn't send.
      def failed(name, error)
        raise error if ArenaRunner::Cancel.foreign?(error)

        Result.new(passed: false, scenario: name, rule: error.rule, load_order: nil)
      end
    end
  end
end
