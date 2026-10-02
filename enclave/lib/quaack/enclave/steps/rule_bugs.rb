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
      # step is what disproved it: step9, step10, or 14c (the rewrite is in
      # result_comparison's "discarded"). A rewrite step 8 pruned for
      # planning as the original does was never tested: its
      # rewrite_tested_<n> says rule discarded, and it isn't a bug.
      #
      # Trust boundary. Entry names, step names, and rule names through
      # RewriteSource, which sends only QUAACK's own.
      module RuleBugs
        module_function

        def call(store)
          discarded = NegativeResult.optional(store, "result_comparison")&.fetch("discarded") || []
          NegativeResult.rewrites(store).filter_map do |rewrite|
            made = RewriteSource.fields(store.read(rewrite))
            step = disproved_by(store, rewrite, discarded) if made["source"] == "rule"
            { "rewrite" => rewrite, "rules" => made["rules"], "step" => step } if step
          end
        end

        # The step that disproved rewrite, or nil.
        def disproved_by(store, rewrite, discarded)
          disproof = NegativeResult.disproved(store, rewrite)
          return disproof["step"] if disproof && disproof["rule"] != "discarded"

          "14c" if discarded.include?(rewrite)
        end
      end
    end
  end
end
