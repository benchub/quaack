# frozen_string_literal: true

require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class ImpliedPredicateRemoval
        Term = Data.define(:container, :index, :condition)

        class WhereContainer
          def initialize(select) = @select = select

          def conditions = Tree.conjuncts(@select.where_clause)

          def conditions=(conditions)
            @select.where_clause = Tree.all_of(conditions)
          end
        end

        class OnContainer
          def initialize(join) = @join = join

          def conditions = Tree.conjuncts(@join.quals)

          def conditions=(conditions)
            @join.quals = Tree.all_of(conditions)
          end
        end
      end
    end
  end
end
