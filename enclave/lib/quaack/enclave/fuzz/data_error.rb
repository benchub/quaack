# frozen_string_literal: true

require_relative "../arena_runner"

module Quaack
  module Enclave
    module Fuzz
      # Whether a query's error came from the data it read: SQLSTATE class
      # 22, data_exception (an overflow, a division by zero, a bad date), or
      # 21, cardinality_violation (a scalar subquery that found a second
      # row). A timeout or a cancel (57014), and every other error, didn't.
      #
      #   DataError.sqlstate?("22012")  # => true
      #   DataError.sqlstate?("57014")  # => false
      #   DataError.candidate_only?(runner, fixture, original, candidate)  # => true or false
      module DataError
        CLASSES = %w[21 22].freeze

        module_function

        def sqlstate?(sqlstate) = sqlstate.is_a?(String) && CLASSES.include?(sqlstate[0, 2])

        # Whether, on fixture, the original runs and then the candidate
        # fails on the data. It raises a cancel that wasn't QUAACK's
        # statement_timeout, which ends the step.
        def candidate_only?(runner, fixture, original, candidate)
          runner.with_fixture(fixture, index_scans: false) do |transaction|
            transaction.query(original)
            transaction.query(candidate)
            false
          end
        rescue ArenaRunner::Error => e
          raise if ArenaRunner::Cancel.foreign?(e)

          e.step == :query && e.index == 1 && sqlstate?(e.sqlstate)
        end
      end
    end
  end
end
