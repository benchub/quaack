# frozen_string_literal: true

require "pg_query"
require_relative "../../deparse"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class ImpliedPredicateRemoval
        module Columns
          def column_and_value(left, right)
            column = left.column_ref if left.node == :column_ref
            found = value(right)
            [column, found] if column && found
          end

          def value(node)
            inner = node.type_cast.arg if node.node == :type_cast
            node = inner || node
            node if node.node == :param_ref
          end

          def typed(value, info)
            sql = "(#{Deparse.expression(value)})::#{info.type}"
            sql = "#{sql} COLLATE #{info.collation}" if info.collation
            PgQuery.parse("SELECT WHERE #{sql}").tree.stmts.first.stmt.select_stmt.where_clause
          end

          def column_info(column, select, catalog)
            name = Tree.qualified(column)
            return unless name

            table = table_for(name.first, select)
            catalog.column_info(table.schemaname, table.relname, name.last) if table
          end

          def table_for(name, select)
            items = Tree.from_items(select.from_clause).select { it.name == name }
            items.first&.table if items.size == 1
          end

          def operator(expr)
            expr.name.map { it.string.sval }.join(".") if expr.name.all? { it.node == :string }
          end
        end
      end
    end
  end
end
