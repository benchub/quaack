# frozen_string_literal: true

require_relative "result_comparator"

module Quaack
  module Enclave
    # DESIGN.md's selection: selection, as pure logic.
    #
    #   Selection.select(minimax: <minimax entry>, result_comparison: <result_comparison entry>)
    #
    # Drops every minimax survivor whose rewrite result-comparison discarded (a label's
    # rewrite is the part before its first ":", so "rewrite_1:top:2" goes
    # with "rewrite_1"; "original:..." index-only candidates are never
    # discarded), ranks the rest by slow blocks and then by the sum across
    # literals, and keeps the top three. It returns:
    #   "top"           [{ "label", "slow_blocks", "total_blocks_sum", "footprint" }], ranked
    #   "excluded"      { label => one of REASONS } for every other candidate.
    #                   A label whose rewrite result-comparison discarded is
    #                   result_mismatch if a failing verdict's rule is one of
    #                   ResultComparator::MISMATCHES, else result_timed_out if
    #                   one is timed_out, else result_not_compared
    #   "infinite_sets" passed on from minimax
    module Selection
      KEEP = 3
      REASONS = %w[result_mismatch result_timed_out result_not_compared below_top_three footprint_tie
                   not_better].freeze
      MISMATCHES = ResultComparator::MISMATCHES.map(&:to_s).freeze

      module_function

      def select(minimax:, result_comparison:)
        discarded = result_comparison["discarded"]
        mismatched, kept = minimax["survivors"].partition { discarded.include?(it["label"].split(":").first) }
        ranked = kept.sort_by { [it["slow_blocks"], it["total_blocks_sum"]] }
        top = ranked.first(KEEP)
        { "top" => top, "excluded" => excluded(minimax, dropped(result_comparison, mismatched), ranked.drop(KEEP), top),
          "infinite_sets" => minimax["infinite_sets"] }
      end

      def excluded(minimax, dropped, below, top)
        ties = minimax["discarded_ties"].to_h { [it, "footprint_tie"] }
        reasons = dropped.merge(labelled(below, "below_top_three"), ties)
        rest = minimax["verdicts"].keys - reasons.keys - top.map { it["label"] }
        reasons.merge(rest.to_h { [it, "not_better"] })
      end

      def dropped(result_comparison, mismatched)
        mismatched.to_h { [it["label"], discard_reason(result_comparison, it["label"])] }
      end

      # Why result-comparison discarded label's rewrite, from its failing verdicts.
      def discard_reason(result_comparison, label)
        verdicts = result_comparison.fetch("verdicts", {})[label.split(":").first]
        rules = verdicts.is_a?(Hash) ? verdicts.values.filter_map { it["rule"] if it["result"] == "fail" } : []
        return "result_mismatch" if rules.intersect?(MISMATCHES)
        return "result_timed_out" if rules.include?("timed_out")

        "result_not_compared"
      end

      def labelled(candidates, reason) = candidates.to_h { [it["label"], reason] }
    end
  end
end
