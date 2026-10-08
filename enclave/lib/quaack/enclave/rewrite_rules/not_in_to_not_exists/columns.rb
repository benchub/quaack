# frozen_string_literal: true

require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class NotInToNotExists
        # The table columns NOT IN compares, each [schema, table, column],
        # and whether NOT EXISTS compares them as NOT IN does.
        module Columns
          module_function

          # A tested column's, or nil.
          def outer(select, column) = column_of(select.from_clause, Tree.qualified(column))

          # A target of a branch's select list's, if it's a column written
          # name.column, or nil.
          def inner(sub, target)
            val = target.res_target.val
            column_of(sub.from_clause, Tree.qualified(val.column_ref)) if val.node == :column_ref
          end

          def column_of(from, (name, column))
            table = Tree.plain_table_named(from, name)
            [table.schemaname, table.relname, column] if table
          end

          # Whether every branch's column in each place has one type and
          # collation, as a UNION compares its columns as their common type.
          def same_types?(branches, catalog)
            return true if branches.size == 1

            places = branches.map { |sub| sub.target_list.map { catalog.column_info(*inner(sub, it)) } }.transpose
            places.all? { |infos| infos.first && infos.uniq.size == 1 }
          end

          # Whether Postgres takes each pair of a row comparison, as it does
          # any one column.
          def row_equalities?(select, tested, branches, catalog)
            return true if tested.size == 1

            branches.all? do |sub|
              tested.zip(sub.target_list).all? { catalog.row_equality?(outer(select, it.first), inner(sub, it.last)) }
            end
          end
        end
      end
    end
  end
end
