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
      # proposed is what its burndown stage added (rewrite-rules, llm-rewrites, operator-rewrites), over
      # every search. Those not kept are the proposals that weren't stored,
      # whichever check dropped them: more than the burndown's arrival rules. Both are nil until the stage is recorded.
      #
      # Indexes. What each source proposed is what index-from-query,
      # index-from-plan, and the LLM rounds (llm-index-ideas, llm-index-refine)
      # added. An LLM round's record also holds its own drops; the
      # generators' already existed and planner ignored are nil, since the
      # burndown counts index-dedupe's and index-test's drops for every source
      # together. Built, not better, and ranked by source are the payload's
      # index_sources, nil if it hasn't any. An index several sources
      # proposed counts in each of their rows (overlap?). The last row counts
      # what the payload carries for every source together, each index once
      # (index_totals).
      module Accountability
        REWRITE_COLUMNS = ["Proposed", "Not kept", "Same plan as the original", "Wrong results",
                           "Not better", "Ranked", "Stopped for another reason"].freeze
        INDEX_COLUMNS = ["Proposed", "Already existed", "Planner ignored", "Built and measured", "Not better",
                         "Ranked"].freeze

        # Each source of rewrites: its row's name, and the stage that
        # counts what it proposed.
        REWRITE_SOURCES = { "rule" => ["QUAACK's own rules", "rewrite-rules"], "llm" => ["The LLM", "llm-rewrites"],
                            "operator" => %w[You operator-rewrites] }.freeze

        # The outcome column a fate counts in. Any other fate is the last.
        OUTCOMES = { "same_plans" => 0, "rewrite_test_disproved" => 1, "counterexamples_disproved" => 1,
                     "production_mismatch" => 1, "not_better" => 2, "ranked" => 3 }.freeze
        OTHER = 4

        LLM_ROUNDS = %w[llm-index-ideas llm-index-refine].freeze

        # index_sources' outcomes, in the table's order.
        BY_SOURCE = %w[built not_better ranked].freeze

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
          proposals = [added("index-from-query"), added("index-from-plan"), added(*LLM_ROUNDS)]
          [["Generator one, from the query's text", proposals[0], nil, nil, *built_by("generator_one")],
           ["Generator two, from the query's plan", proposals[1], nil, nil, *built_by("generator_two")],
           ["The LLM", proposals[2], dropped(LLM_ROUNDS, %w[covered_by_existing]),
            dropped(LLM_ROUNDS, %w[never_used hypopg_refused]), *built_by("llm")],
           ["All sources together", (proposals.sum if proposals.all?), *index_totals]]
        end

        # The source's built, not better, and ranked counts from the
        # payload's index_sources, or nils without it.
        def built_by(source)
          counts = index_sources&.fetch(source, nil)
          counts ? counts.values_at(*BY_SOURCE) : [nil] * BY_SOURCE.size
        end

        def index_sources = @payload["index_sources"]

        # Whether the index rows by source can add up to more than all
        # sources together, which they can once they count built indexes.
        def overlap? = !index_sources.nil?

        # What the payload carries for every source together. Already
        # existed and planner ignored are counted as the proposals are, from
        # the burndown, over every search, so an idea that came up in two
        # searches counts twice: index-dedupe's and index-test's drops of the
        # generators' ideas, and the LLM rounds' own. Each is nil unless both
        # are recorded. A negative result's lists hold each index once, so
        # they'd count a different thing. The built, not better, and ranked
        # columns count each built index once. One is ranked if a ranked
        # candidate ran with it (Indexes#proposed). The not better and
        # ranked columns needn't add up to the built ones: see
        # not_better_indexes.
        def index_totals
          [together(%w[index-dedupe], %w[covered_by_existing]),
           together(%w[index-test], %w[never_used hypopg_refused]), indexes.size, not_better_indexes.size,
           proposed.size]
        end

        # The generators' stage's drops for reasons, plus the LLM rounds'.
        def together(stages, reasons)
          counts = [dropped(stages, reasons), dropped(LLM_ROUNDS, reasons)]
          counts.sum if counts.all?
        end

        # The built indexes that were not better: at least one measured
        # label ran with it, and selection excluded every one of them as
        # not_better. One label that did anything else keeps the index out,
        # so an index with mixed labels (one not better, one that beat the
        # original and tied) isn't counted here. Neither is one whose label
        # tied, fell below the top three, was dropped in result-comparison, or timed out,
        # nor one no label ran with. Those count only as built.
        def not_better_indexes
          indexes.keys.select do |name|
            ran = labels.select { it["indexes"].include?(name) }
            !ran.empty? && ran.all? { excluded[it["label"]] == "not_better" }
          end
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
