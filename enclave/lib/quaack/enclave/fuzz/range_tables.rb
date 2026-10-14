# frozen_string_literal: true

require_relative "../table_name"

module Quaack
  module Enclave
    module Fuzz
      # The tables a column's qualifier names, while Facts walks a query: a
      # stack of the FROM items of each SELECT it's inside, by the name the
      # query refers to them by.
      #
      #   tables.enter(select[:from_clause])
      #   tables.table(["a"])  # => TableName for the innermost "a", or nil
      #   tables.leave
      class RangeTables
        def initialize
          @scopes = []
        end

        def enter(from_clause) = @scopes.push(named(from_clause))

        def leave = @scopes.pop

        # The table a column's qualifier names: schema and table, or a FROM
        # item's name in the innermost SELECT that has it. nil for a CTE,
        # subquery, function or join alias, whose columns aren't a table's,
        # and for an unqualified column.
        def table(qualifier)
          case qualifier
          in [schema, name] then TableName.new(schema:, name:)
          in [name] then @scopes.reverse_each.find { it.key?(name) }&.fetch(name)
          else nil
          end
        end

        private

        def named(items, found = {})
          Array(items).each do |item|
            if (var = item[:range_var])
              found[var.dig(:alias, :aliasname) || var[:relname]] = relation(var)
            else
              named(item[:join_expr].values_at(:larg, :rarg), found) if item[:join_expr]
              name = item.values.first.dig(:alias, :aliasname)
              found[name] = nil if name
            end
          end
          found
        end

        # A CTE's name has no schema.
        def relation(var)
          TableName.new(schema: var[:schemaname], name: var[:relname]) unless var[:schemaname].to_s.empty?
        end
      end
    end
  end
end
