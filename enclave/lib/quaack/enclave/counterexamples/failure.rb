# frozen_string_literal: true

require_relative "../arena_runner"
require_relative "../result_comparison/original_rerun"

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
      # failed. original_fails? asks ResultComparison::OriginalRerun, which runs the original's own comparison
      # again, against itself, and decides by the step a runner error there names, never Postgres's message.
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

        # Whether a query of the original's comparison against itself fails on the prepared fixture
        # (ResultComparison::OriginalRerun).
        def original_fails?(runner, prepared, original)
          ResultComparison::OriginalRerun.fails?(runner, prepared.rows, original, inserts: prepared.inserts)
        end
      end
    end
  end
end
