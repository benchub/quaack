# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class SubqueryDistinctRemoval
        # Whether a SELECT's DISTINCT or GROUP BY only merges copies of a
        # value that its reader can't tell apart.
        #
        # DISTINCT and GROUP BY merge the values that their type's equality
        # calls equal, and keep one of each. A reader that compares them
        # another way could tell the merged ones apart. text = citext
        # compares as text, so it tells 'ann' from 'ANN', which a citext
        # DISTINCT merges. A COLLATE "C" on the tested value does the same
        # to a column of a case-insensitive collation. Then which copy the
        # DISTINCT kept would decide the answer, and without it both are
        # there.
        #
        # So Columns.comparable? holds only when each item of the select
        # list is a column of a table in the SELECT's own FROM, whose
        # Catalog::Column is comparable: a built-in type that hashes and
        # sorts, or an enum, with no collation or a deterministic one. Each
        # of those types' equality either holds only for the same value
        # (text with a deterministic collation, the integers, uuid) or, for
        # numeric, the floats, interval, and bpchar, merges values that
        # every implicit cast to another type keeps equal. So any = a reader
        # could compare them with calls the merged copies equal too.
        #
        # name.column is the column of the one FROM item of that name, which
        # must be a schema-qualified table with no column aliases
        # (Tree.plain_table?). A bare column is the column of the one FROM
        # table that has it, when every FROM item is such a table, under a
        # name of its own (Tree.tables?). A column no FROM item has belongs
        # to an outer query, and is refused, as is a star or an expression.
        module Columns
          module_function

          def comparable?(select, catalog)
            items = Tree.from_items(select.from_clause)
            select.target_list.all? do |target|
              names = names(target.res_target.val)
              names && column(names, items, catalog)&.comparable
            end
          end

          # The names of a column reference, with nil for a star, or nil
          # for any other node. No column has a star's name.
          def names(node) = (node.column_ref.fields.map { it.string&.sval } if node&.node == :column_ref)

          def column(names, items, catalog)
            case names.size
            when 2 then of(items.select { it.name == names.first }, names.last, catalog)
            when 1 then bare(items, names.first, catalog)
            end
          end

          def bare(items, column, catalog)
            return unless Tree.tables?(items)

            found = items.filter_map { of([it], column, catalog) }
            found.first if found.size == 1
          end

          # The Catalog::Column of the one item in named, if it's a plain
          # table that has the column.
          def of(named, column, catalog)
            table = named.first.table if named.size == 1
            catalog.columns(table.schemaname, table.relname).find { it.name == column } if
              table && Tree.plain_table?(table)
          end
        end
      end
    end
  end
end
