# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # The report's index tables: the indexes QUAACK built (DESIGN.md's report),
      # and, in a negative result, the ones the planner declined and the
      # ones that already existed (negative-result).
      #
      # Only a ranked candidate's indexes are proposed. The rest were built
      # and measured, and nothing came of them, so the report doesn't call
      # them proposed. When nothing is ranked, none is.
      module Indexes
        DECLINED = { "unused" => "The planner never chose it.",
                     "unrenderable" => "QUAACK couldn't write its definition." }.freeze
        HYPOPG = "HypoPG, which QUAACK uses to try an index without building it, couldn't create it"

        # The built indexes a ranked candidate ran with, by name.
        def proposed = ranked_labels.flat_map { measured(it)&.fetch("indexes") || [] }.uniq & indexes.keys

        def unproposed = indexes.keys - proposed

        # An existing index with its size from the planner statistics.
        def existing(index)
          size = index["size_bytes"] ? Format.size(index["size_bytes"]) : "size #{Words::MISSING}"
          "#{Format.sql_span(index["name"])} (#{size})"
        end

        def searches(entry) = entry["searches"].map { Words.search(it, run_id) }.join(", ")

        def declined(entry)
          return DECLINED[entry["reason"]] || Words::MISSING unless entry["reason"] == "hypopg_refused"

          "#{HYPOPG}#{" (Postgres error code #{entry["sqlstate"]})" if entry["sqlstate"]}."
        end
      end
    end
  end
end
