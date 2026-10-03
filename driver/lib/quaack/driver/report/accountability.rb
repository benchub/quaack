# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # Who proposed what, and what became of it: one table for rewrites
      # and one for indexes, a row per source and a column per outcome.
      #
      # A cell is a count, or nil where the payload doesn't carry it, which
      # the report shows as "not recorded" and never as zero.
      #
      # Rewrites. The payload gives every stored rewrite a source and a
      # fate, so the outcome columns are always counts. How many each source
      # proposed is what its burndown stage added (6c, 6a, step 7), over
      # every search. Those refused on arrival are the proposals that
      # weren't stored. Both are nil until the stage is recorded.
      #
      # Indexes. The payload doesn't say which source proposed a built,
      # declined, or existing index, so most cells by source are nil. What
      # each source proposed is what 5a-1, 5a-2, and the LLM rounds (5a-5,
      # 5a-6) added. An LLM round's record also holds its own drops. The
      # last row counts what the payload does carry, whatever the source.
      module Accountability
        REWRITE_COLUMNS = ["Proposed", "Refused on arrival", "Same plan as the original", "Wrong results",
                           "Not better", "Ranked", "Stopped for another reason"].freeze
        INDEX_COLUMNS = ["Proposed", "Already existed", "Planner ignored", "Built and measured", "Not better",
                         "Ranked"].freeze

        # Each source of rewrites: its row's name, and the stage that
        # counts what it proposed.
        REWRITE_SOURCES = { "rule" => ["QUAACK's own rules", "6c"], "llm" => ["The LLM", "6a"],
                            "operator" => %w[You step7] }.freeze

        # The outcome column a fate counts in. Any other fate is the last.
        OUTCOMES = { "same_plans" => 0, "step9_disproved" => 1, "step10_disproved" => 1,
                     "production_mismatch" => 1, "not_better" => 2, "ranked" => 3 }.freeze
        OTHER = 4

        LLM_ROUNDS = %w[5a-5 5a-6].freeze

        def rewrite_account
          rows = REWRITE_SOURCES.map do |source, (name, stage)|
            [name, *rewrite_counts(rewrites.select { it["source"] == source }, added(stage))]
          end
          unknown = rewrites.reject { REWRITE_SOURCES.key?(it["source"]) }
          unknown.empty? ? rows : rows + [["Source #{Words::MISSING}", *rewrite_counts(unknown, nil)]]
        end

        def rewrite_counts(kept, proposed)
          refused = proposed - kept.size if proposed && proposed >= kept.size
          outcomes = kept.map { OUTCOMES.fetch(it["fate"], OTHER) }
          [proposed, refused, *Array.new(OTHER + 1) { |column| outcomes.count(column) }]
        end

        def index_account
          proposals = [added("5a-1"), added("5a-2"), added(*LLM_ROUNDS)]
          [["Generator one, from the query's text", proposals[0], *[nil] * 5],
           ["Generator two, from the query's plan", proposals[1], *[nil] * 5],
           ["The LLM", proposals[2], dropped(LLM_ROUNDS, %w[covered_by_existing]),
            dropped(LLM_ROUNDS, %w[never_used hypopg_refused]), nil, nil, nil],
           ["All sources together", (proposals.sum if proposals.all?), *index_totals]]
        end

        # What the payload carries for every source together: the declined
        # and existing indexes of a negative result, each counted once, and
        # the built indexes, by whether a ranked candidate ran with one
        # (Indexes#proposed).
        def index_totals
          [negative && negative["existing"].size, negative && negative["declined"].size, indexes.size,
           unproposed.size, proposed.size]
        end

        # Every search's record of each stage.
        def records(*stages) = stages.flat_map { burndown["stages"].fetch(it, {}).values }

        # What the stages added, or nil if none is recorded.
        def added(*stages)
          found = records(*stages)
          found.sum { it["added"].values.sum } unless found.empty?
        end

        # What the stages dropped for reasons, or nil if none is recorded.
        def dropped(stages, reasons)
          found = records(*stages)
          found.sum { it["dropped"].slice(*reasons).values.sum } unless found.empty?
        end

        def unrecorded? = (rewrite_account + index_account).flatten.any?(&:nil?)
      end
    end
  end
end
