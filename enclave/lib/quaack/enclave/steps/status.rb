# frozen_string_literal: true

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
                     rewrites_generated].freeze

        module_function

        def call(store:, **)
          [{ type: :status, entries: (ENTRIES + rewrite_entries(store)).to_h { [it, store.entry?(it)] } }]
        end

        # For each stored rewrite_<n>, counting up from 1: its name and the
        # names of its step 8, 9, and 10 outputs. Only names of this fixed form go out.
        def rewrite_entries(store)
          (1..).lazy.take_while { store.entry?("rewrite_#{it}") }.flat_map do |n|
            ["rewrite_#{n}", "index_search_rewrite_#{n}", "index_ranking_rewrite_#{n}", "rewrite_pruned_#{n}",
             "rewrite_tested_#{n}", "rewrite_survived_#{n}"]
          end.to_a
        end
      end
    end
  end
end
