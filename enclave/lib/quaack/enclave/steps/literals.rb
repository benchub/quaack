# frozen_string_literal: true

require_relative "../literal_set"
require_relative "volatility"

module Quaack
  module Enclave
    module Steps
      # `quaacks literals --run <run ID>` (DESIGN.md's literals): builds the run's
      # literal sets (see LiteralSet).
      #
      # It runs after `quaacks redact`, and refuses with its own rule,
      # volatility_not_passed, unless `quaacks volatility` stored its passed
      # marker. It reads placeholder_map, redacted_query, and statistics,
      # and doesn't touch production. LiteralSet.run writes one entry,
      # literal_sets, only after everything is computed, so a refusal or a
      # missing entry stores nothing. The sets hold real values, so nothing
      # of them is sent. Its only line is DONE.
      module Literals
        class Error < StandardError
          def rule = "volatility_not_passed"
        end

        class UsedError < StandardError
          def rule = "literals_already_used"
        end

        # The entries of steps that measure with the sets, in separate
        # processes, and compare their numbers by set name.
        USERS = /\A(baseline|index_baseline|candidate_runs|result_comparison|index_search_.+)\z/

        module_function

        def call(store:, **)
          passed = store.entry?(Volatility::ENTRY) && store.read(Volatility::ENTRY) == { "passed" => true }
          raise Error unless passed
          raise UsedError if store.entry_names.any? { it.match?(USERS) }

          LiteralSet.run(store:, sql: store.read("redacted_query"))
          []
        end
      end
    end
  end
end
