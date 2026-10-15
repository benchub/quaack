# frozen_string_literal: true

require_relative "../arena_runner"
require_relative "../result_comparison"

module Quaack
  module Enclave
    module ResultComparison
      # Whether the original query, not the candidate, failed when a comparison of the two (compare_in_load_orders)
      # raised a runner error that isn't a load's: counterexample-compare's rounds (Counterexamples::Failure) ask it.
      #
      #   OriginalRerun.fails?(runner, rows, original, inserts:)  # => true or false
      #
      # The comparison runs many queries, built from either query, so the error alone can't say whose query
      # failed. fails? runs the original's own comparison again, the original against itself, where every query is
      # the original's, and the decision follows the step a runner error there names, never Postgres's message.
      module OriginalRerun
        module_function

        # Whether a query of the original's comparison against itself fails on rows (and inserts), in any load
        # order compare_in_load_orders runs. Each load order runs to its end, whatever its verdict. A load that
        # fails ends the search with false: the comparison that failed couldn't have got past it either, so the
        # original ran everywhere that comparison reached. It counts as LOAD_ORDERS.size loads, as
        # compare_in_load_orders does.
        def fails?(runner, rows, original, inserts: [])
          runner.counted_as(LOAD_ORDERS.size) do
            ResultComparison.distinct_loads(rows, runner).map(&:last).each do |positions|
              ran = rerun(runner, positions.map { rows[it] }, inserts, original)
              return ran == :query_failed unless ran == :ran
            end
            false
          end
        end

        # How the original's comparison against itself went on one load of rows: :ran, :query_failed, or
        # :not_loaded when a runner error came at any other step. A cancel QUAACK didn't send goes up, and ends
        # the step.
        def rerun(runner, rows, inserts, original)
          runner.with_fixture(rows, inserts:, index_scans: false) do |tx|
            ResultComparison.compare(tx, original:, candidate: original)
          end
          :ran
        rescue ArenaRunner::Error => e
          raise if ArenaRunner::Cancel.foreign?(e)

          e.step == :query ? :query_failed : :not_loaded
        end
      end
    end
  end
end
