# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class DistinctKeyRemoval
        # The keys the rule rests on, each as the assumptions that state it:
        # one of the first table's, which the select list holds, and one of
        # each joined table's, which its ON pairs with the tables before it.
        # A key is only ever one of the catalog's candidates (Catalog#keys)
        # that it proves: the fewest columns win, then the one whose last
        # column comes first, then the index made first.
        module Keys
          module_function

          # unique and not_null for a key of root the select list holds,
          # every column of it written root.column, or root.* for all its
          # columns, each with a deterministic collation or none. Another
          # read of a key column, such as root.id + 0, doesn't count. nil
          # if there's none.
          def root(select, root, catalog)
            columns = selected(select, root, catalog)
            key = candidates(catalog, root, columns).find do |candidate|
              unique_not_null(root, candidate).all? { catalog.met?(it) } &&
                candidate.all? { catalog.column_info(*pair(root), it).deterministic }
            end
            unique_not_null(root, key) if key
          end

          # unique for a key of join's table whose every column the ON
          # pairs with a column of a table before it, or nil.
          def join(join, catalog)
            paired = join.conditions.filter_map { paired(it, join, catalog) }.uniq
            key = candidates(catalog, join.table, paired).find { catalog.met?(unique(join.table, it)) }
            [unique(join.table, key)] if key
          end

          # The candidate keys of table made of columns alone, best first.
          def candidates(catalog, table, columns)
            keys = catalog.keys(*pair(table)).select { (it - columns).empty? }
            keys.sort_by.with_index { |key, i| [key.size, key.map { columns.index(it) }.max, i] }
          end

          # The columns of root that the select list holds, in order.
          def selected(select, root, catalog)
            name = Tree.refname(root)
            select.target_list.flat_map do |target|
              case fields(target.res_target.val)
              in [^name, :a_star] then catalog.column_names(*pair(root))
              in [^name, String => column] then [column]
              else []
              end
            end.uniq
          end

          def fields(node) = node.column_ref&.fields&.map { it.node == :string ? it.string.sval : it.node }

          # The joined table's column that condition pairs with a column of
          # a table before it, or nil. The condition must be a plain
          # unqualified = between two columns written name.column, of one
          # base type or two integer types (one_family?), each with a deterministic collation or none, whose =
          # is the type's default btree family's (Catalog#default_btree?).
          # With the unique assumption's = being that family's too, at most
          # one row of the joined table is = to each value.
          def paired(condition, join, catalog)
            own, other = sides(condition, Tree.refname(join.table))
            table = join.before.find { Tree.refname(it) == other.first } if own
            own.last if table && pairable?(catalog, [*pair(join.table), own.last], [*pair(table), other.last])
          end

          # The two columns condition equates, the one of the table named
          # name first, or nil unless one is.
          def sides(condition, name)
            refs = equated(condition)
            refs = refs.reverse if refs && refs.first.first != name
            refs if refs&.first&.first == name
          end

          # The two columns, each [name, column], of a plain unqualified =
          # between two columns written name.column, or nil.
          def equated(condition)
            expr = condition.a_expr if condition.node == :a_expr
            return unless expr&.kind == :AEXPR_OP && expr.name.map { it.string.sval } == ["="]

            refs = [expr.lexpr, expr.rexpr].map { it.column_ref && Tree.qualified(it.column_ref) }
            refs if refs.all?
          end

          # Whether the pair is comparable?, or two integers whose = is the
          # key's integer_ops one. Only this rule's joins take the second.
          def pairable?(catalog, column, other)
            comparable?(catalog, column, other, integers: true)
          end

          def comparable?(catalog, column, other, integers: false)
            info, other_info = [column, other].map { catalog.column_info(*it) }
            info && other_info && one_family?(info.base_type, other_info.base_type, integers) && info.deterministic &&
              other_info.deterministic && catalog.default_btree?(*column)
          end

          # Postgres's integer types, whose = across any two of them is an
          # operator of integer_ops, the family of each one's default btree
          # opclass, as an int column joined to a bigint key is.
          INTEGERS = %w[smallint integer bigint].freeze

          # Whether = between the two base types is the key type's own
          # family's: the types are one, or, if integers, both are integers.
          def one_family?(type, other, integers)
            type == other || (integers && [type, other].all? { INTEGERS.include?(it) })
          end

          def unique_not_null(table, key)
            [unique(table, key), *key.map { { "kind" => "not_null", "table" => name(table), "column" => it } }]
          end

          def unique(table, key) = { "kind" => "unique", "table" => name(table), "columns" => key }

          def name(table) = pair(table).join(".")

          def pair(range) = [range.schemaname, range.relname]
        end
      end
    end
  end
end
