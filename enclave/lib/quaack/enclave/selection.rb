# frozen_string_literal: true

module Quaack
  module Enclave
    # README 14d: selection, as pure logic.
    #
    #   Selection.select(minimax: <minimax entry>, result_comparison: <result_comparison entry>)
    #
    # Drops every minimax survivor whose rewrite 14c discarded (a label's
    # rewrite is the part before its first ":", so "rewrite_1:top:2" goes
    # with "rewrite_1"; "original:..." index-only candidates are never
    # discarded), ranks the rest by slow blocks and then by the sum across
    # literals, and keeps the top three. It returns:
    #   "top"           [{ "label", "slow_blocks", "total_blocks_sum", "footprint" }], ranked
    #   "excluded"      { label => "result_mismatch" | "below_top_three" |
    #                     "footprint_tie" | "not_better" } for every other candidate
    #   "infinite_sets" passed on from minimax
    module Selection
      KEEP = 3

      module_function

      def select(minimax:, result_comparison:)
        discarded = result_comparison["discarded"]
        mismatched, kept = minimax["survivors"].partition { discarded.include?(it["label"].split(":").first) }
        ranked = kept.sort_by { [it["slow_blocks"], it["total_blocks_sum"]] }
        top = ranked.first(KEEP)
        { "top" => top, "excluded" => excluded(minimax, mismatched, ranked.drop(KEEP), top),
          "infinite_sets" => minimax["infinite_sets"] }
      end

      def excluded(minimax, mismatched, below, top)
        ties = minimax["discarded_ties"].to_h { [it, "footprint_tie"] }
        reasons = labelled(mismatched, "result_mismatch").merge(labelled(below, "below_top_three"), ties)
        rest = minimax["verdicts"].keys - reasons.keys - top.map { it["label"] }
        reasons.merge(rest.to_h { [it, "not_better"] })
      end

      def labelled(candidates, reason) = candidates.to_h { [it["label"], reason] }
    end
  end
end
