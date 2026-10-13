# frozen_string_literal: true

require_relative "../arena_runner"
require_relative "../result_comparison"

module Quaack
  module Enclave
    module Counterexamples
      # The round whose comparison failed with a runner error (Counterexamples.compare), by what failed: the
      # fixture's load (its rule, load_failed), the original (original_failed), or the candidate where the original
      # ran (the runner's rule, a disproof).
      #
      #   Failure.round(runner, prepared, original, error)
      #   # => #<data Round match=nil, rule=:original_failed, ...>
      #
      # The comparison runs many queries, built from either query, so the error alone can't say whose query
      # failed. original_fails? runs the original's own comparison again, the original against itself, where every
      # query is the original's, and the decision follows the step a runner error there names, never Postgres's
      # message.
      module Failure
        module_function

        def round(runner, prepared, original, error)
          if LOAD_RULES.include?(error.rule) || LOAD_STEPS.include?(error.step)
            return Round.new(match: nil, rule: error.rule, load_order: nil, covered: [], load_failed: true)
          end
          if original_fails?(runner, prepared, original)
            return Round.new(match: nil, rule: :original_failed, load_order: nil, covered: [], load_failed: false)
          end

          Round.new(match: false, rule: error.rule, load_order: nil, covered: [], load_failed: false)
        end

        # Whether a query of the original's comparison against itself fails on the prepared fixture, in any load
        # order compare_in_load_orders runs. Each load order runs to its end, whatever its verdict. A load that
        # fails ends the search with false: the comparison that failed couldn't have got past it either, so the
        # original ran everywhere that comparison reached. It counts as LOAD_ORDERS.size loads, as
        # compare_in_load_orders does.
        def original_fails?(runner, prepared, original)
          runner.counted_as(ResultComparison::LOAD_ORDERS.size) do
            ResultComparison.distinct_loads(prepared.rows, runner).map(&:last).each do |positions|
              ran = rerun(runner, positions.map { prepared.rows[it] }, prepared.inserts, original)
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
