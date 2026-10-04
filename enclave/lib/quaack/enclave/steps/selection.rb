# frozen_string_literal: true

require_relative "../selection"

module Quaack
  module Enclave
    module Steps
      # `quaacks selection --run <run ID>` (DESIGN.md's selection): reads minimax and
      # result_comparison and writes selection as Enclave::Selection.select
      # returns it. Its only line is DONE.
      module Selection
        module_function

        def call(store:, **)
          store.write("selection", Enclave::Selection.select(minimax: store.read("minimax"),
                                                             result_comparison: store.read("result_comparison")))
          []
        end
      end
    end
  end
end
