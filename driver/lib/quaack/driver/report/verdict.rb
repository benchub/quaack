# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # Mixed into View: the verdict (DESIGN.md's report). A headline, one table with a row
      # for each kind of change and the original as it is, ranked by improvement, and short
      # caveats that link to their detail lower in the report.
      module Verdict
        # The best row must read at least this share fewer blocks on the slow values for the
        # headline to say "substantial".
        SUBSTANTIAL_PERCENT = 30
        HEADLINES = { substantial: "The verdict: substantial improvements possible",
                      minor: "The verdict: minor improvements possible",
                      nothing: "The verdict: QUAACK found nothing that could help" }.freeze
        PLANS = { "rewrite_new_indexes" => "Best rewrite, with new indexes",
                  "rewrite_same_indexes" => "Best rewrite, with the same indexes",
                  "original_new_indexes" => "The original query, with new indexes" }.freeze
        SAME = "The original query, with the same indexes"

        def headline
          return HEADLINES[:nothing] unless winner

          theirs = original_measurements.dig("slow", "total_blocks")
          HEADLINES[substantial?(winner["slow_blocks"], theirs) ? :substantial : :minor]
        end

        # Whether ours is at least SUBSTANTIAL_PERCENT fewer blocks than theirs. Any finish
        # beats an original that timed out.
        def substantial?(ours, theirs)
          return original_measurements.dig("slow", "timed_out") == true unless theirs

          theirs.positive? && (theirs - ours) * 100 >= SUBSTANTIAL_PERCENT * theirs
        end

        # The table's rows, as hashes: real candidates by blocks, then the baseline, then
        # the kinds with no candidate, each with its reason as :warn and :hover.
        def verdict_rows
          best = ranked_by_kind.to_h { |kind, entries| [kind, entries.first] }
          found = best.map { |kind, entry| candidate_row(kind, entry) }.sort_by { it[:blocks] }
          missing = Protocol::CandidateKinds::KINDS.reject { best.key?(it) }.map { missing_row(it) }
          [*found, baseline_row, *missing]
        end

        def candidate_row(kind, entry)
          ours = entry["slow_blocks"]
          theirs = original_measurements.dig("slow", "total_blocks")
          { plan: PLANS.fetch(kind), detail: describe(entry["label"]), blocks: ours, blocks_text: Format.number(ours),
            delta: kind == "rewrite_same_indexes" ? "0" : added_size(entry["label"]),
            improvement: improvement(ours, theirs) }
        end

        def baseline_row
          { plan: SAME, blocks: Float::INFINITY, blocks_text: total(original_measurements["slow"]), delta: "0",
            improvement: "0%" }
        end

        def improvement(ours, theirs)
          return "the original query timed out" unless theirs
          return "n/a" if theirs.zero?

          "#{Format.apart(ours, theirs)}%"
        end

        # The built size of a label's new indexes, "+56.0 MB".
        def added_size(label)
          sizes = (measured(label)&.fetch("indexes", nil) || []).map { indexes.dig(it, "size") }
          return Words::MISSING unless sizes.all?(Integer)

          "+#{Format.size(sizes.sum)}"
        end

        def missing_row(kind)
          tried = labels.select { kind_of(it) == kind }
          reason, hover = tried.empty? ? nothing_tried(kind) : nothing_won(kind, tried)
          { plan: PLANS.fetch(kind), warn: reason, hover:, delta: "n/a", improvement: "n/a" }
        end

        def nothing_tried(kind)
          if kind == "original_new_indexes"
            ["No new index found that the original query could use",
             "QUAACK built #{Words.count(indexes.size, "index", "indexes")} in all, and none was measured with " \
             "the original query."]
          else
            ["No rewrite survived testing",
             "QUAACK kept #{Words.count(rewrites.size, "rewrite")}, and none was measured " \
             "#{kind == "rewrite_same_indexes" ? "with no new indexes" : "with new indexes"}. " \
             "The queries section says what became of each."]
          end
        end

        def nothing_won(kind, tried)
          timed = tried.count { it["timed_out"] }
          hover = "QUAACK measured #{Words.count(tried.size, "candidate")} of this kind, and none made the " \
                  "ranking.#{" #{Words.count(timed, "candidate")} timed out." if timed.positive?} " \
                  "The ranking section says why."
          reason = case kind
                   when "rewrite_same_indexes" then "No rewrite beat the original without an index"
                   when "rewrite_new_indexes" then "No rewrite with new indexes beat the original"
                   else "No new index beat the original query"
                   end
          [reason, hover]
        end

        # Short caveats, as [sentence, link target].
        def caveats
          runs = ["#{Words.count(timed_out_count, "measurement run")} of candidates timed out, and QUAACK dropped " \
                  "those candidates.", "ranking"]
          original = ["#{Candidates::ORIGINAL.capitalize} timed out on the " \
                      "#{list(infinite_sets.map { Words.set(it) })} values, so any candidate that finished there " \
                      "counts as better.", "ranking"]
          [*([runs] if timed_out_count.positive?), *([original] unless infinite_sets.empty?),
           *([[hidden_statistics, "indexes"]] if hidden_statistics)]
        end
      end
    end
  end
end
