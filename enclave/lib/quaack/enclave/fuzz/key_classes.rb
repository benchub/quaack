# frozen_string_literal: true

module Quaack
  module Enclave
    module Fuzz
      # Columns a join or a foreign key ties together, as classes
      # (union-find over [table, column]).
      class KeyClasses
        def initialize = @parent = {}

        def member?(column) = @parent.key?(column)

        def join(left, right) = @parent[find(left)] = find(right)

        def join_foreign_keys(keys)
          keys.each { |key| key.columns.zip(key.parent_columns).each { |c, p| join([key.child, c], [key.parent, p]) } }
        end

        def members(column)
          root = find(column)
          @parent.keys.select { find(it) == root }
        end

        private

        def find(column)
          @parent[column] ||= column
          @parent[column] = find(@parent[column]) unless @parent[column] == column
          @parent[column]
        end
      end
    end
  end
end
