# frozen_string_literal: true

require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # `quaacks status --run <run ID>`: sends one status message saying
      # which step outputs the run's store holds, so `quaack run` can resume
      # by skipping the steps already done. entries maps each name in
      # ENTRIES, a fixed list of entry names, to whether it's there. Only
      # the names and booleans go out, never an entry's data. Each
      # orchestration task adds the entries its stage needs.
      module Status
        ENTRIES = %w[index_search_original index_generated_original index_ranking_original
                     rewrites_generated operator_rewrites_checked arena_setup index_build baseline
                     index_baseline candidate_runs minimax result_comparison selection].freeze

        module_function

        def call(store:, **)
          entries = (ENTRIES + rewrite_entries(store)).to_h { [it, store.entry?(it)] }
          [{ type: :status, entries: entries.merge(step11_entries(store)) }]
        end

        # For each stored rewrite_<n>, counting up from 1: its name and the
        # names of its step 8, 9, and 10 outputs. Only names of this fixed form go out.
        def rewrite_entries(store)
          (1..).lazy.take_while { store.entry?("rewrite_#{it}") }.flat_map do |n|
            ["rewrite_#{n}", "index_search_rewrite_#{n}", "index_ranking_rewrite_#{n}", "rewrite_pruned_#{n}",
             "rewrite_tested_#{n}", "rewrite_survived_#{n}"]
          end.to_a
        end

        # DESIGN.md step 11, for each stored rewrite_<n>: rewrite_step11_<n>,
        # whether IndexSearch.llm_search? takes it, and whether its 5a-5 ran
        # (index_generated_) and its 5a-7 ran after that (index_llm_ranked_).
        def step11_entries(store)
          (1..).lazy.take_while { store.entry?("rewrite_#{it}") }.flat_map do |n|
            names = ["index_generated_rewrite_#{n}", "index_llm_ranked_rewrite_#{n}"]
            [["rewrite_step11_#{n}", IndexSearch.llm_search?(store, "rewrite_#{n}")]] +
              names.map { [it, store.entry?(it)] }
          end.to_h
        end
      end
    end
  end
end
