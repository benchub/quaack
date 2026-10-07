# frozen_string_literal: true

module Quaack
  module Enclave
    module Steps
      # The step_counts messages of index-search and index-rank (see
      # Protocol::StepCounts), from the entry each stores. Only counts.
      module StepCounts
        module_function

        # index-search's: found, how many candidates it tested, and used,
        # how many of those the planner used on some literal set.
        def index_search(entry)
          results = entry["results"]
          { type: :step_counts, found: results.size, used: results.count { used?(it) } }
        end

        # index-rank's: ranked, how many single indexes made the top, and
        # combined, how many indexes the best combination holds (0 for none).
        def index_rank(ranking)
          combination = ranking["combination"]
          { type: :step_counts, ranked: ranking["top"].size, combined: combination ? combination["ddl"].size : 0 }
        end

        # Whether a tested candidate went in and the planner used it.
        def used?(result) = !result["refusal"] && result["plans"].values.any? { it["used"] }
      end
    end
  end
end
