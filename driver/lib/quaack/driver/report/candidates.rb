# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # A measured label in words. The payload names a candidate by a label
      # such as original:top:1, which says nothing to a reader, so the
      # report says what it is: the query it ran, and the new indexes it
      # ran with, from the label's entry in the payload's labels.
      #
      #   describe("original:top:1")  # => "Your query with a new index on public.t (a, b)"
      #   describe("rewrite_2:none")  # => "Rewrite Silver Fox with no new indexes"
      #
      # It also says, for each label selection left out of the ranking, what it
      # read against the original and why that wasn't enough.
      module Candidates
        ORIGINAL = "your query as it is"
        LOST = { "footprint_tie" => "beat #{ORIGINAL}, but tied with a candidate whose new indexes take less " \
                                    "disk space.",
                 "below_top_three" => "beat #{ORIGINAL}, but three other candidates did better." }.freeze

        # The label's entry in the payload's labels, or nil.
        def measured(label) = labels.find { it["label"] == label }

        def describe(label)
          search, key = label.to_s.split(":", 2)
          "#{search == "original" ? "Your query" : Words.rewrite(search, run_id)} #{with(measured(label), key)}"
        end

        # The new indexes a label ran with. Without the label's entry, only
        # whether it had any, which its name says.
        def with(entry, key)
          return key == "none" ? "with no new indexes" : "with new indexes" unless entry

          on = entry["indexes"].map { target(it) }
          return "with no new indexes" if on.empty?
          return "with a new index #{on.first}" if on.size == 1

          "with new indexes #{list([on.first, *on.drop(1).map { it.delete_prefix("on ") }])}"
        end

        # A built index by what it's on, such as "on public.t (a, b)", from
        # its DDL. A method other than btree stays in the SQL just as the
        # DDL gives it, such as "on public.t USING gin (b)", so what's set
        # apart pastes after CREATE INDEX ON as working SQL.
        def target(name)
          ddl = indexes.dig(name, "ddl") or return "QUAACK couldn't describe (#{Format.sql_span(name)})"
          on, table, method, rest = IndexDdl.parts(ddl)
          return "on #{Format.sql_span(ddl)}" unless table

          "on #{Format.sql_span(method == "btree" ? "#{table} #{rest}" : on)}"
        end

        def list(items) = items.size < 3 ? items.join(" and ") : "#{items[0..-2].join(", ")}, and #{items.last}"

        # A row for each measured label that isn't ranked: selection's
        # excluded ones, then the ones whose measurement timed out. A row is
        # what the label was, who proposed its rewrite (nil for your query,
        # or when the payload doesn't say), and why it wasn't ranked.
        def unranked
          excluded.map { |label, reason| unranked_row(label, lost(label, reason)) } +
            timed_out_labels.map { unranked_row(it, "timed out while QUAACK measured it.") }
        end

        def unranked_row(label, why)
          who = (r = rewrite_of(label)) && source(r)
          [describe(label), who && Words.upper(who), Words.upper(why)]
        end

        # The labels that timed out, which selection neither ranks nor excludes.
        def timed_out_labels = labels.select { it["timed_out"] }.map { it["label"] } - excluded.keys - ranked_labels

        def ranked_labels = top.map { it["label"] }

        def lost(label, reason)
          return LOST[reason] if LOST.key?(reason)
          return not_better(label) if reason == "not_better"
          return "wasn't ranked." unless reason == "result_mismatch"

          "was dropped when QUAACK compared the rewrite's results with your query's on the real data. " \
            "See #{Words.search(label.to_s.split(":").first, run_id)} under the queries."
        end

        # Why minimax found a label not better, with the blocks that say so.
        def not_better(label)
          entry = measured(label) || {}
          ours, theirs = blocks(entry, "slow")
          return "was no better than #{ORIGINAL}." unless ours && theirs
          return "#{slow_blocks(ours, theirs)}, which isn't more than 5% fewer." unless better?(entry, "slow")

          worse = (entry["verdicts"] || {}).key("worse") or return "was no better than #{ORIGINAL}."
          "read fewer blocks on the slow values (#{pair(ours, theirs)}), but #{worse_on(entry, worse)}"
        end

        def better?(entry, set) = entry.dig("verdicts", set) == "better"

        def slow_blocks(ours, theirs)
          "read #{Format.number(ours)} blocks on the slow values, against #{Format.number(theirs)} for #{ORIGINAL}"
        end

        def pair(ours, theirs) = "#{Format.number(ours)}, against #{Format.number(theirs)}"

        def worse_on(entry, set)
          ours, theirs = blocks(entry, set)
          return "timed out on the #{Words.set(set)} values." unless ours
          return "was worse on the #{Words.set(set)} values." unless theirs

          "read #{Format.number(ours)} on the #{Words.set(set)} values, against #{Format.number(theirs)} for " \
            "#{ORIGINAL}, which is more than 5% more."
        end

        # The label's blocks and the original's on one literal set, each nil
        # if it timed out or wasn't measured.
        def blocks(entry, set)
          [entry.dig("measurements", set, "total_blocks"), original_measurements.dig(set, "total_blocks")]
        end

        # A ranked label's measurements, one row of cells per literal set.
        def measurement_rows(label)
          entry = measured(label) || {}
          (entry["measurements"] || {}).map do |set, counts|
            [Words.set(set), total(counts), total(original_measurements[set]), Format.number(counts["hit"]),
             Format.number(counts["read"]), against(entry, set),
             counts["stable"] == false ? "unstable: the count changed between runs" : ""]
          end
        end

        # The label's blocks against the original's on one literal set, or
        # its verdict where either number is missing.
        def against(entry, set) = Format.against(*blocks(entry, set)) || verdict_words(entry.dig("verdicts", set))

        def verdict_words(verdict)
          return Words::MISSING unless verdict

          Words::VERDICTS.fetch(verdict) { Words.plain(verdict) }
        end

        # One literal set's blocks, for the label or the original.
        def total(counts)
          return Words::MISSING unless counts
          return "timed out" if counts["timed_out"]

          counts["total_blocks"].is_a?(Integer) ? Format.number(counts["total_blocks"]) : Words::MISSING
        end

        # The ranking table's cells for your query as it is: its blocks on
        # the slow values, and summed over the sets of values the ranked
        # candidates were summed over.
        def baseline
          [total(original_measurements["slow"]), baseline_sum]
        end

        def baseline_sum
          counts = baseline_sets.map { original_measurements[it] }
          return "timed out" if counts.any? { it&.dig("timed_out") }
          return Words::MISSING unless counts.all? { it&.dig("total_blocks").is_a?(Integer) }

          counts.sum { it["total_blocks"] }
        end

        # The sets the original measured, and any a ranked candidate measured.
        def baseline_sets
          original_measurements.keys | top.flat_map { measured(it["label"])&.dig("measurements")&.keys || [] }
        end
      end
    end
  end
end
