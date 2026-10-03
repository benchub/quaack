# frozen_string_literal: true

module Quaack
  module Enclave
    module Steps
      # Every label steps 13a and 14 measured, for ReportPayload's labels
      # field (DESIGN.md step 15): the original under each of its index
      # combinations (index_baseline), then each rewrite's runs
      # (candidate_runs), then the rewrite runs candidate-runs dropped for
      # timing out. Ranked or not, each one goes out, so the report can say
      # what any label was and how many blocks it read.
      #
      #   MeasuredLabels.call(store)
      #   # => [{ "label" => "rewrite_1:top:1", "search" => "rewrite_1",
      #   #       "indexes" => ["quaack_ab12"], "timed_out" => false,
      #   #       "measurements" => { set => { "total_blocks", "hit", "read",
      #   #                                    "stable", "timed_out" } },
      #   #       "verdicts" => { set => "better" | "no_worse" | "worse" } }]
      #
      # indexes is the built names of the indexes it ran with (none for
      # <search>:none). measurements is nil for a rewrite run that timed
      # out, which candidate-runs doesn't keep. A set that timed out is
      # { "timed_out" => true }. hit and read are the run with the most
      # blocks. verdicts is minimax's, nil for a label minimax never judged
      # (one that timed out).
      #
      # Trust boundary. Counts, booleans, set names, built index names, and
      # labels. A label goes out only if it matches LABEL, the labels
      # QUAACK makes itself: a search and "none" or an IndexBuild
      # combination key.
      module MeasuredLabels
        LABEL = /\A(?:original|rewrite_[1-9]\d*):(?:none|combination|(?:top|set_aside):[1-9]\d*)\z/

        module_function

        def call(store)
          build = store.read("index_build")["combinations"]
          verdicts = store.read("minimax")["verdicts"]
          measured(store).select { |label, _| LABEL.match?(label) }.map do |label, sets|
            { "label" => label, "search" => label.split(":").first, "indexes" => build.fetch(label, []),
              **blocks(sets), "verdicts" => verdicts[label] }
          end
        end

        def blocks(sets)
          return { "timed_out" => true, "measurements" => nil } unless sets

          { "timed_out" => sets.values.any? { it["timed_out"] },
            "measurements" => sets.transform_values { summary(it) } }
        end

        # [label, its sets or nil] pairs, in the order they were measured.
        def measured(store)
          runs = store.read("candidate_runs")
          rewrites = runs["candidates"].flat_map do |search, by_key|
            by_key.map { |key, sets| [key == "none" ? "#{search}:none" : key, sets] }
          end
          store.read("index_baseline")["combinations"].to_a + rewrites + runs["timed_out"].map { [it, nil] }
        end

        def summary(measurement)
          return { "timed_out" => true } if measurement["timed_out"]

          worst = measurement["runs"].max_by { it["total_blocks"] }
          { "total_blocks" => measurement["total_blocks"], "hit" => worst["hit"], "read" => worst["read"],
            "stable" => measurement["stable"], "timed_out" => false }
        end
      end
    end
  end
end
