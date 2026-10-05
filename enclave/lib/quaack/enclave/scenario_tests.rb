# frozen_string_literal: true

require "pg_query"
require_relative "arena_runner"
require_relative "denormalized_fixture"
require_relative "result_comparison"
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
    # compare_in_both_orders), each in its own arena transactions that roll
    # back. The first scenario that doesn't match disproves the candidate,
    # and the rest don't run. Its Result names the scenario, the verdict's
    # rule (such as :multiset, or :unsupported_order for a refusal) and
    # load order. A candidate that fails in arena is disproved too, with the
    # runner's rule (such as :query_failed) and no load order. A candidate
    # that matches every scenario passes, with scenario nil.
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
      # loaded in arena (ArenaRunner#loads), the guard's included.
      Report = Data.define(:results, :untested, :untested_atoms, :retries, :dropped, :refused, :cycle, :loads)
      Result = Data.define(:passed, :scenario, :rule, :load_order)

      module_function

      def run(conn, sql, candidates, statement_timeout_ms: 10_000, honour: [])
        runner = DenormalizedFixture::Runner.new(conn, honour, statement_timeout_ms:)
        builder = Scenarios::Builder.new(conn, PgQuery.parse(sql))
        guard = VacuityGuard.run(runner, builder, sql)
        results = candidates.map { |candidate| test(runner, guard.scenarios, builder.spills, sql, candidate) }
        tested(guard, builder, results, runner.loads)
      rescue Scenarios::Error => e
        refused(candidates, e.rule, cycle: e.cycle, loads: runner.loads)
      end

      # The report of candidates tested on the guard's scenarios.
      def tested(guard, builder, results, loads)
        Report.new(results:, untested: guard.untested, untested_atoms: guard.untested_atoms, retries: guard.retries,
                   dropped: builder.dropped, refused: nil, cycle: nil, loads:)
      end

      def refused(candidates, rule, cycle: nil, loads: 0)
        results = candidates.map { Result.new(passed: false, scenario: nil, rule:, load_order: nil) }
        Report.new(results:, untested: [], untested_atoms: [], retries: 0, dropped: 0, refused: rule,
                   cycle: (cycle if rule == :fk_cycle), loads:)
      end

      # A scenario's further fixtures (spills, see Scenarios::Parts) run
      # after its first, under its name.
      def test(runner, scenarios, spills, sql, candidate)
        Scenarios::NAMES.each do |name|
          [scenarios.fetch(name), *spills.fetch(name, [])].each do |rows|
            verdict = ResultComparison.compare_in_both_orders(runner, rows, original: sql, candidate:)
            next if verdict.match?

            return Result.new(passed: false, scenario: name, rule: verdict.rule, load_order: verdict.load_order)
          rescue ArenaRunner::Error => e
            return Result.new(passed: false, scenario: name, rule: e.rule, load_order: nil)
          end
        end
        Result.new(passed: true, scenario: nil, rule: nil, load_order: nil)
      end
    end
  end
end
