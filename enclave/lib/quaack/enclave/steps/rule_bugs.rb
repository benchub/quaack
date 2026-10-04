# frozen_string_literal: true

require_relative "negative_result"
require_relative "rewrite_source"

module Quaack
  module Enclave
    module Steps
      # DESIGN.md 6c, for ReportPayload's rule_bugs field: the rule-made
      # rewrites a test disproved. Rules are sound by design, so each one is
      # a bug in QUAACK, and the report says so prominently.
      #
      #   RuleBugs.call(store)
      #   # => [{ "rewrite" => "rewrite_1", "rules" => ["key_in_self_join"], "step" => "step9" }]
      #
      # step is what disproved it: step9, step10, or 14c. A rewrite step 8
      # pruned for planning as the original does was never tested: its
      # rewrite_tested_<n> says rule discarded, and it isn't a bug.
      #
      # A rewrite resting on a denormalized_equal assumption isn't sound by
      # design: 6b found the data holds it, and steps 9 and 10 make up their
      # own data, which needn't. So their disproof of it isn't a bug. 14c's
      # is, since 14c runs on the racetrack's data, which 6b checked.
      #
      # 14c disproves a rewrite only when one of its failing verdicts in
      # result_comparison is a result mismatch, a rule in MISMATCHES. 14c
      # drops a candidate for any failing verdict, but two of its rules
      # compare nothing: timed_out (the rewrite, run with no index shown,
      # ran past the timeout) and unsupported_order (the original's order
      # can't be checked, so every candidate fails). Neither says the
      # rewrite is wrong. MISMATCHES lists the rules that do, so a rule 14c
      # gains later isn't called a bug until it's added here:
      #   column_count, column_types  the output columns differ
      #   row_count, value, multiset, subset  the rows differ
      #   candidate_unordered  the rewrite lost the original's ORDER BY
      #
      # Trust boundary. Entry names, step names, and rule names through
      # RewriteSource, which sends only QUAACK's own.
      module RuleBugs
        MISMATCHES = %w[column_count column_types row_count value multiset subset candidate_unordered].freeze

        module_function

        def call(store)
          verdicts = NegativeResult.optional(store, "result_comparison")&.fetch("verdicts") || {}
          NegativeResult.rewrites(store).filter_map do |rewrite|
            entry = store.read(rewrite)
            made = RewriteSource.fields(entry)
            step = disproved_by(store, rewrite, verdicts, EmpiricalAssumptions.any?(entry)) if made["source"] == "rule"
            { "rewrite" => rewrite, "rules" => made["rules"], "step" => step } if step
          end
        end

        # The step that disproved rewrite, or nil. Steps 9 and 10 don't count
        # for a rewrite resting on what the data holds.
        def disproved_by(store, rewrite, verdicts, empirical)
          disproof = NegativeResult.disproved(store, rewrite)
          return disproof["step"] if disproof && disproof["rule"] != "discarded" && !empirical

          "14c" if verdicts.fetch(rewrite, {}).each_value.any? { mismatch?(it) }
        end

        # Whether a 14c verdict says the results differed. Only a failing
        # verdict carries one of MISMATCHES: a pass has no rule, and a
        # partial one has subset_timed_out.
        def mismatch?(verdict) = MISMATCHES.include?(verdict["rule"])
      end
    end
  end
end
