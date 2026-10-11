# frozen_string_literal: true

require_relative "../arena_runner"
require_relative "../result_comparator"
require_relative "../result_comparison"

module Quaack
  module Enclave
    module VacuityGuard
      # The fixture-compare runs a guard run makes for atoms equal rows
      # leave vacuous under a top-level LIMIT or OFFSET (20261010-26).
      #
      #   compared = Compared.new(MAX_COMPARISONS)
      #   compared.mismatch?(runner, rows, sql, loosened_query, inserts)  # => true or false
      #
      # A comparison already made with no mismatch isn't run again: a retry
      # often rebuilds the same fixture, and it would give the same verdict.
      # Nor is one past the cap. Either way mismatch? says false, so the
      # atom stays vacuous: neither ever counts an atom tested.
      class Compared
        def initialize(cap = Float::INFINITY)
          @cap = cap
          @seen = Set.new
          @runs = 0
        end

        # Whether fixture-compare, in every load order, finds the loosened
        # query a mismatch. A refusal compares nothing, so it isn't one, and
        # nor is a comparison that fails to run.
        def mismatch?(runner, rows, sql, query, inserts)
          key = [rows, query, inserts]
          return false if @seen.include?(key) || @runs >= @cap

          @runs += 1
          found = compare(runner, rows, sql, query, inserts)
          @seen.add(key) unless found
          found
        end

        private

        # Its loads aren't counted (ArenaRunner#uncounted): whether equal
        # rows leave an atom vacuous follows the LIMIT's value (LIMIT 1
        # hides a loosened atom, LIMIT 2 doesn't), so how many comparisons
        # run does too (20261010-47).
        def compare(runner, rows, sql, query, inserts)
          verdict = runner.uncounted do
            ResultComparison.compare_in_load_orders(runner, rows, original: sql, candidate: query, inserts:)
          end
          ResultComparator::MISMATCHES.include?(verdict.rule)
        rescue ArenaRunner::Error
          false
        end
      end
    end
  end
end
