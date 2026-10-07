# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class UnusedJoinRemoval
        # Counts the column references that might read a table of a
        # SELECT's FROM. Only references inside that SELECT can: SQL resolves
        # a name.column in the innermost FROM that binds the name, then
        # outward, so a reference in another branch of a UNION, in an outer
        # query, or in a CTE the SELECT doesn't hold never reads it.
        #
        # It's conservative. Inside the SELECT, a reference name.column or
        # name.* skips the table only when a nested SELECT's own FROM binds
        # the name and the reference is in that SELECT's select list, WHERE,
        # GROUP BY, HAVING, ORDER BY, WINDOW, or DISTINCT ON, which see that
        # FROM first. A name in a FROM binds when it's a table's, or the
        # alias of a subquery, a function, or a join; a join with an alias
        # hides the names inside it. Every other reference that names the
        # table counts, and so does any bare column of one of its columns,
        # at any depth, since it might be the table's.
        module Reads
          module_function

          # The fields of a SelectStmt whose references see its FROM first.
          SCOPED = %w[target_list where_clause group_clause having_clause sort_clause window_clause
                      distinct_clause].freeze

          # How many column references in select might read its table named
          # name, whose columns are columns.
          def count(select, name, columns) = fields(select, name, columns, false)

          def fields(select, name, columns, shadowed)
            select.class.descriptor.sum { walk(it.get(select), name, columns, shadowed) }
          end

          def walk(node, name, columns, shadowed)
            case node
            when Google::Protobuf::RepeatedField then node.sum { walk(it, name, columns, shadowed) }
            when PgQuery::Node then walk(node.inner, name, columns, shadowed)
            when PgQuery::ColumnRef then might_read?(node, name, columns, shadowed) ? 1 : 0
            when PgQuery::SelectStmt then nested(node, name, columns, shadowed)
            when Google::Protobuf::MessageExts then fields(node, name, columns, shadowed)
            else 0
            end
          end

          # The count in a SELECT nested in the one whose table it counts.
          def nested(select, name, columns, shadowed)
            binds = select.from_clause.any? { bound(it).include?(name) }
            select.class.descriptor.sum do |field|
              walk(field.get(select), name, columns, shadowed || (binds && SCOPED.include?(field.name)))
            end
          end

          # Whether ref might read the table named name: it names it, or it's
          # a bare column of one of its columns. Under shadowed, a nested
          # SELECT's FROM binds name, so name.column and name.* are that one's.
          def might_read?(ref, name, columns, shadowed)
            parts = ref.fields.map { it.string&.sval }
            return false if shadowed && parts.size == 2 && parts.first == name

            parts.include?(name) || (parts.size == 1 && columns.include?(parts.first))
          end

          # The names a FROM item binds, as far as the rule knows them.
          def bound(node)
            case node.node
            when :range_var then [Tree.refname(node.range_var)]
            when :range_subselect, :range_function then [node.inner.alias&.aliasname].compact
            when :join_expr
              join = node.join_expr
              join.alias ? [join.alias.aliasname] : bound(join.larg) + bound(join.rarg)
            else []
            end
          end
        end
      end
    end
  end
end
