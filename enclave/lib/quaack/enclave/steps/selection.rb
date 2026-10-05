# frozen_string_literal: true

require_relative "../selection"
require_relative "../rewrite_burndown"

module Quaack
  module Enclave
    module Steps
      # `quaacks selection --run <run ID>` (DESIGN.md's selection): reads minimax and
      # result_comparison and writes selection as Enclave::Selection.select
      # returns it, once measurement's burndown is recorded
      # (RewriteBurndown.record_measurement). Its only line is DONE.
      module Selection
        module_function

        def call(store:, **)
          selection = Enclave::Selection.select(minimax: store.read("minimax"),
                                                result_comparison: store.read("result_comparison"))
          RewriteBurndown.record_measurement(store, selection)
          store.write("selection", selection)
          []
        end
      end
    end
  end
end
