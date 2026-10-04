# frozen_string_literal: true

require_relative "../minimax"

module Quaack
  module Enclave
    module Steps
      # `quaacks minimax --run <run ID>` (DESIGN.md's blocks-metric, minimax): compares every
      # candidate_runs run ("rewrite_<n>:none" or its combination key) and
      # the original under each index-baseline combination that didn't time out
      # (index-only candidates) against the bare original baseline, with
      # Enclave::Minimax. A candidate's footprint is the sum of the built
      # index sizes in its combination (0 for none). It writes minimax as
      # Minimax.decide returns it. Its only line is DONE.
      module Minimax
        module_function

        def call(store:, **)
          store.write("minimax", Enclave::Minimax.decide(original: store.read("baseline")["sets"],
                                                         candidates: candidates(store)))
          []
        end

        def candidates(store)
          build = store.read("index_build")
          index = store.read("index_baseline")
          runs = rewrite_runs(store) + index["combinations"].except(*index["timed_out"]).map { |k, s| [k, k, s] }
          runs.map { |label, key, sets| { "label" => label, "sets" => sets, "footprint" => footprint(build, key) } }
        end

        # [label, combination key or "none", sets] for each candidate run.
        def rewrite_runs(store)
          store.read("candidate_runs")["candidates"].flat_map do |search, by_key|
            by_key.map { |key, sets| [key == "none" ? "#{search}:none" : key, key, sets] }
          end
        end

        def footprint(build, key)
          build["combinations"].fetch(key, []).sum { build["indexes"].fetch(it)["size"] }
        end
      end
    end
  end
end
