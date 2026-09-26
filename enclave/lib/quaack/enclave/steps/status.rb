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
        ENTRIES = %w[index_search_original index_generated_original index_ranking_original].freeze

        module_function

        def call(store:, **)
          [{ type: :status, entries: ENTRIES.to_h { [it, store.entry?(it)] } }]
        end
      end
    end
  end
end
