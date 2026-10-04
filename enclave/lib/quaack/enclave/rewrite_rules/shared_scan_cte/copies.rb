# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class SharedScanCte
        # Finding a table's copies in the top-level FROM, and the reads of
        # them that rule them out.
        module Copies
          private

          # [schema, table] for each table the top-level FROM reads more
          # than once.
          def tables(top)
            (items(top) || []).select { copy?(it) }.group_by { key(it.table) }.select { _2.size > 1 }.keys
          end

          # The top-level FROM items, if each has a name. One without, such
          # as an aliased join, could hide a copy of the same name.
          def items(top)
            items = Tree.from_items(top.from_clause)
            items if items.none? { it.name.nil? }
          end

          def copy?(item) = item.table && Tree.plain_table?(item.table)

          def key(range) = [range.schemaname, range.relname]

          def taken?(tree, name)
            Tree.find(tree, PgQuery::CommonTableExpr).any? { it.ctename == name }
          end

          # Whether any column reference reads a copy's whole row: the bare
          # alias, or alias.* anywhere but on its own in the select list.
          def whole_row?(tree, top, names)
            listed = top.target_list.filter_map { it.res_target.val&.column_ref }
            Tree.find(tree, PgQuery::ColumnRef).any? do |ref|
              names.include?(ref.fields.first.string&.sval) && whole?(ref, listed)
            end
          end

          def whole?(ref, listed)
            ref.fields.size == 1 || (ref.fields.last.node == :a_star && listed.none? { it == ref })
          end
        end
      end
    end
  end
end
