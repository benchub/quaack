# frozen_string_literal: true

require "pg_query"
require_relative "../value_pools"

module Quaack
  module Enclave
    module Scenarios
      # Whether a query may read a column, by name alone, whatever table
      # it names, which errs toward yes. A star, or a reference whose last
      # name is no column of a fixture table (a whole row, such as t in
      # SELECT t FROM x t, or an output name), counts as reading every
      # column.
      class Reads
        def initialize(parse, column_names)
          @names = []
          @all = false
          known = column_names.values.flatten
          walk(parse.tree) { |fields| note(fields, known) }
        end

        def read?(name) = @all || @names.include?(name)

        private

        def walk(node, &)
          yield node.fields.to_a if node.is_a?(PgQuery::ColumnRef)
          ValuePools::Sides.children(node).each { walk(it, &) }
        end

        def note(fields, known)
          name = fields.last&.string&.sval
          @names << name if name
          @all = true unless name && known.include?(name)
        end
      end
    end
  end
end
