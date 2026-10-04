# frozen_string_literal: true

require "pg_query"
require_relative "arena_runner"
require_relative "result_comparison"
require_relative "scenarios"
require_relative "vacuity_guard"

module Quaack
  module Enclave
    # Step 9, end to end, for one query and its candidates.
    #
    #   report = StepNine.run(arena_connection, original_sql, [candidate_sql, ...])
    #   report.results  # => [Result(passed: true, scenario: nil, ...), Result(passed: false, scenario: :s2, ...)]
    #   report.untested # => 9c's untested atoms, by redacted shape
    #
    # It builds the scenarios (Scenarios), runs the 9c guard on S1
    # (VacuityGuard), and then, for each candidate in order, runs S0
    # through S6 through 9d's comparison (ResultComparison.
    # compare_in_both_orders), each in its own arena transactions that roll
    # back. The first scenario that doesn't match disproves the candidate,
    # and the rest don't run. Its Result names the scenario, the verdict's
    # rule (such as :multiset, or :unsupported_order for a refusal) and
    # load order. A candidate that fails in arena is disproved too, with the
    # runner's rule (such as :query_failed) and no load order. A candidate
    # that matches every scenario passes, with scenario nil.
    #
    # Trust boundary: the report holds booleans, symbols, counts, and 9c's
    # redacted shapes. The fixtures, with the real literals, stay here.
    module StepNine
      # dropped counts the scenario groups left out because they collide on
      # a unique key (Scenarios::Builder#dropped).
      Report = Data.define(:results, :untested, :untested_atoms, :retries, :dropped)
      Result = Data.define(:passed, :scenario, :rule, :load_order)

      module_function

      def run(conn, sql, candidates, statement_timeout_ms: 10_000)
        runner = ArenaRunner.new(conn, statement_timeout_ms:)
        builder = Scenarios::Builder.new(conn, PgQuery.parse(sql))
        guard = VacuityGuard.run(runner, builder, sql)
        results = candidates.map { |candidate| test(runner, guard.scenarios, builder.spills, sql, candidate) }
        Report.new(results:, untested: guard.untested, untested_atoms: guard.untested_atoms, retries: guard.retries,
                   dropped: builder.dropped)
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
