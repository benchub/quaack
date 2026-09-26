# frozen_string_literal: true

module Quaack
  module Enclave
    # README 14a and 14b: the metric and the minimax rule, as pure logic.
    #
    #   Minimax.decide(original: { set => measurement },
    #                  candidates: [{ "label", "sets" => { set => measurement }, "footprint" }])
    #
    # Compares total_blocks only (for an unstable literal Measurement already
    # stores the max of the three runs). "better" is more than 5% fewer
    # blocks, "no_worse" an increase within 5%, else "worse". A set where the
    # original timed out counts as infinite: any finishing candidate is
    # better there, and the set is listed in "infinite_sets". A survivor is
    # better on the slow literal and no worse on every other. Two survivors
    # within 5% of each other on the slow literal tie, and the one with the
    # larger footprint is discarded. The rest are ranked by slow blocks, then
    # by the sum across literals. It returns:
    #   "survivors"      [{ "label", "slow_blocks", "total_blocks_sum", "footprint" }], ranked
    #   "verdicts"       { label => { set => verdict } }
    #   "discarded_ties" labels dropped by the footprint tiebreaker
    #   "infinite_sets"  sets where the original timed out
    module Minimax
      SLOW = "slow"
      PERCENT = 5

      module_function

      # original is nil when the original timed out (infinite).
      def verdict(candidate, original)
        return "better" if original.nil?
        return "better" if candidate * 100 < original * (100 - PERCENT)

        candidate * 100 <= original * (100 + PERCENT) ? "no_worse" : "worse"
      end

      def decide(original:, candidates:)
        base = original.transform_values { it["timed_out"] ? nil : it["total_blocks"] }
        candidates = finished(candidates)
        verdicts = candidates.to_h { [it["label"], verdicts(it, base)] }
        passing = passing(candidates, verdicts)
        discarded = discarded(passing)
        { "survivors" => rank(passing - discarded), "verdicts" => verdicts,
          "discarded_ties" => discarded.map { it["label"] }, "infinite_sets" => infinite(base) }
      end

      def infinite(base)
        base.select { |_, b| b.nil? }.keys
      end

      # Candidates with no timed-out measurement.
      def finished(candidates)
        candidates.reject { |c| c["sets"].values.any? { it["timed_out"] } }
      end

      def passing(candidates, verdicts)
        candidates.select { survives?(verdicts[it["label"]]) }.map { summary(it) }
      end

      def rank(survivors)
        survivors.sort_by { [it["slow_blocks"], it["total_blocks_sum"]] }
      end

      def verdicts(candidate, base)
        base.to_h { |set, blocks| [set, verdict(candidate["sets"].fetch(set)["total_blocks"], blocks)] }
      end

      # Greedy by footprint (then slow blocks): a survivor is discarded when
      # it ties one already kept, so a discarded one knocks out nobody.
      def discarded(passing)
        kept = []
        passing.sort_by { [it["footprint"], it["slow_blocks"], it["total_blocks_sum"]] }.each do |a|
          kept << a if kept.none? { |b| tie?(a, b) }
        end
        passing - kept
      end

      def survives?(verdicts)
        verdicts[SLOW] == "better" && verdicts.values.none?("worse")
      end

      def tie?(first, second)
        low, high = [first["slow_blocks"], second["slow_blocks"]].minmax
        high * 100 <= low * (100 + PERCENT)
      end

      def summary(candidate)
        blocks = candidate["sets"].transform_values { it["total_blocks"] }
        { "label" => candidate["label"], "slow_blocks" => blocks.fetch(SLOW),
          "total_blocks_sum" => blocks.values.sum, "footprint" => candidate["footprint"] }
      end
    end
  end
end
