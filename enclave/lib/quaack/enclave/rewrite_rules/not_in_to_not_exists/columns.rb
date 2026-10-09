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
          # collation, as a UNION compares its columns as their common type,
          # and, when the UNION dedupes, Postgres can dedupe that type.
          def same_types?(sub, branches, catalog)
            return true if branches.size == 1

            places = branches.map { |branch| infos(branch, catalog) }.transpose
            places.all? { |infos| infos.first && infos.uniq.size == 1 } &&
              (!deduped?(sub) || unionable?(branches.first, catalog))
          end

          # The type, without its typmod, and the collation of each column a
          # branch selects. A typmod changes neither the type's = nor what
          # a UNION dedupes on, since a value is stored already cut to it,
          # and a UNION of varchar(10) and varchar(20) is of varchar.
          def infos(branch, catalog)
            branch.target_list.map do |target|
              info = catalog.column_info(*inner(branch, target))
              [info.base_type, info.collation] if info
            end
          end

          # Whether Postgres can dedupe each column a branch selects.
          def unionable?(branch, catalog) = branch.target_list.all? { catalog.unionable?(inner(branch, it)) }

          # Whether a set operation has a UNION without ALL anywhere in it.
          def deduped?(sub)
            sub.op == :SETOP_UNION && (!sub.all || deduped?(sub.larg) || deduped?(sub.rarg))
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
