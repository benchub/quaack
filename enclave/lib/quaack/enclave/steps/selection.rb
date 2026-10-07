# frozen_string_literal: true

require_relative "../selection"
require_relative "../rewrite_burndown"

module Quaack
  module Enclave
    module Steps
      # `quaacks selection --run <run ID>` (DESIGN.md's selection): reads minimax and
      # result_comparison and writes selection as Enclave::Selection.select
      # returns it, once measurement's burndown is recorded
      # (RewriteBurndown.record_measurement). It sends one step_counts: top,
      # how many choices it kept, and excluded, how many it left out. Then
      # DONE.
      module Selection
        module_function

        def call(store:, **)
          selection = Enclave::Selection.select(minimax: store.read("minimax"),
                                                result_comparison: store.read("result_comparison"))
          RewriteBurndown.record_measurement(store, selection)
          store.write("selection", selection)
          [{ type: :step_counts, top: selection["top"].size, excluded: selection["excluded"].size }]
        end
      end
    end
  end
end
