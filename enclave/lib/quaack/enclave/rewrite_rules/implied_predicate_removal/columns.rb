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
            [column, *found] if column && found
          end

          # [the placeholder, and the TypeName it's cast to or nil], for a
          # placeholder cast at most once.
          def value(node)
            cast = node.type_cast if node.node == :type_cast
            param = cast ? cast.arg : node
            [param, cast&.type_name] if param.node == :param_ref
          end

          # Whether a literal cast to type_name, or not cast, reads as the
          # column's own type, modifiers included. Any other cast changes
          # the value the column is compared with, as 2.7::int does.
          def own_type?(type_name, info, catalog)
            return true unless type_name

            cast = Tree.where_of("SELECT WHERE NULL::int")
            cast.type_cast.type_name = Deparse.copy(type_name)
            sql = Deparse.expression(cast)
            sql.start_with?("NULL::") && catalog.type_name(sql.delete_prefix("NULL::")) == info.type
          rescue Deparse::Error
            false
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
