# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class ExistenceInFlip
        # The existence check's ORDER BY. Every row it returns is the same
        # constants, so the order picks nothing, and the rewrite sorts by
        # its first output column instead, a placeholder. The original's
        # keys read its FROM, which moves into the EXISTS, and sorting can
        # fail at run time, as 1 / 0 does, or a json[] does when two rows
        # compare. So each key must be an output position in the select list, or a column
        # written name.column of a plain table in the original's FROM,
        # whose type the catalog calls comparable, with no USING operator.
        module Ordering
          module_function

          # Whether select's ORDER BY, if it has one, can become ORDER BY 1.
          # With no select list, ORDER BY 1 doesn't prepare.
          def kept?(select, catalog) = select.sort_clause.all? { key?(it.sort_by, select, catalog) }

          def key?(sort_by, select, catalog)
            return false if sort_by.sortby_dir == :SORTBY_USING

            node = sort_by.node
            case node.node
            when :column_ref then comparable?(Tree.qualified(node.column_ref), select.from_clause, catalog)
            when :a_const then position?(node.a_const.ival, select.target_list.size)
            else false
            end
          end

          # Whether ival is an integer naming a column of the select list. A
          # position outside it makes the original fail, which the rewrite's
          # ORDER BY 1 wouldn't.
          def position?(ival, columns) = !ival.nil? && ival.ival.between?(1, columns)

          def comparable?(column, from, catalog)
            table = column && Tree.from_items(from).find { it.name == column.first }&.table
            return false unless table && Tree.plain_table?(table)

            catalog.columns(table.schemaname, table.relname).find { it.name == column.last }&.comparable || false
          end

          # Makes select's ORDER BY, if it has one, ORDER BY 1.
          def keep!(select)
            return if select.sort_clause.empty?

            select.sort_clause.replace(PgQuery.parse("SELECT 1 ORDER BY 1").tree.stmts.first.stmt.select_stmt
                                         .sort_clause.to_a)
          end
        end
      end
    end
  end
end
