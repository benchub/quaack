# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class UnusedJoinRemoval
        # One join the rule might remove from a tree: the SELECT whose FROM
        # holds it, the joined table's RangeVar, the joining table's, the
        # [joining column, joined column] pairs of its conditions, and a
        # lambda that removes it and them from the tree it was found in.
        Removal = Data.define(:select, :joined, :joining, :pairs, :remove)

        # Finds the joins whose shape the rule takes (see
        # UnusedJoinRemoval), before it asks whether anything else reads the
        # joined table or the catalog proves the foreign key.
        module Candidates
          module_function

          # Every Removal of the shape in tree, in tree order: in each
          # SELECT, its inner JOINs, outermost first, then its comma join's
          # items.
          def in(tree) = every(tree, PgQuery::SelectStmt).flat_map { joins(it) + commas(it) }

          # Every node of type in node, those inside one another included,
          # in tree order. Tree.find stops at the first of each branch.
          def every(node, type, found = [])
            case node
            when Google::Protobuf::RepeatedField then node.each { every(it, type, found) }
            when PgQuery::Node then every(node.inner, type, found)
            when Google::Protobuf::MessageExts
              found << node if node.is_a?(type)
              node.class.descriptor.each { every(it.get(node), type, found) }
            end
            found
          end

          # The inner JOINs in select's FROM that might go, with either side
          # the joined table.
          def joins(select)
            slots(select).flat_map do |join, put|
              next [] unless join.jointype == :JOIN_INNER && join.alias.nil? && join.quals

              [[join.rarg, join.larg], [join.larg, join.rarg]].filter_map do |joined, rest|
                found(select, joined, [rest], Tree.conjuncts(join.quals)) { put.call(rest) }
              end
            end
          end

          # Each JoinExpr in select's FROM, outside subqueries, with a
          # lambda that puts another node in its place.
          def slots(select)
            select.from_clause.each_with_index.flat_map do |node, i|
              slots_in(node, ->(other) { select.from_clause[i] = other })
            end
          end

          def slots_in(node, put)
            return [] unless node.node == :join_expr

            join = node.join_expr
            [[join, put], *slots_in(join.larg, ->(other) { join.larg = other }),
             *slots_in(join.rarg, ->(other) { join.rarg = other })]
          end

          # The items of select's comma-separated FROM that might go, each
          # with the WHERE conjuncts that compare a column of it with
          # another's.
          def commas(select)
            from = select.from_clause
            conjuncts = Tree.conjuncts(select.where_clause)
            from.each_with_index.filter_map do |joined, i|
              next unless joined.node == :range_var

              mine = conjuncts.select { sides(it, Tree.refname(joined.range_var)) }
              found(select, joined, from.to_a - [joined], mine) { uncomma(select, i, conjuncts - mine) }
            end
          end

          # Takes the item at index out of select's FROM and leaves its WHERE
          # the conjuncts kept.
          def uncomma(select, index, kept)
            select.from_clause.delete_at(index)
            select.where_clause = Tree.all_of(kept)
          end

          # A Removal of joined, a node of select's FROM, joined to a table
          # of rest, FROM nodes, by conditions, or nil unless every
          # condition is an = between a column of joined and one of a single
          # table that Tree.plain_table_named finds in rest.
          def found(select, joined, rest, conditions, &remove)
            table = joined.range_var if joined.node == :range_var
            return unless table && Tree.plain_table?(table)

            sides = conditions.map { sides(it, Tree.refname(table)) }
            joining = joining(rest, sides)
            Removal.new(select:, joined: table, joining:, pairs: sides.map { it.drop(1) }, remove:) if joining
          end

          # The RangeVar of the one table of rest every one of sides joins,
          # or nil.
          def joining(rest, sides)
            qualifiers = sides.map { it&.first }.uniq
            Tree.plain_table_named(rest, qualifiers.first) if qualifiers.size == 1 && qualifiers.first
          end

          # [joining name, joining column, joined column] for a condition
          # that's a plain = between a column of name and one of another
          # name, or nil.
          def sides(condition, name)
            joined, joining = columns(condition)&.partition { it.first == name }
            [*joining.first, joined.first.last] if joining&.size == 1
          end

          # The two columns, each [name, column], that condition compares
          # with a plain unqualified =, or nil.
          def columns(condition)
            expr = condition.a_expr if condition.node == :a_expr
            return unless expr&.kind == :AEXPR_OP && expr.name.map { it.string&.sval } == ["="]

            columns = [expr.lexpr, expr.rexpr].map { column(it) }
            columns if columns.all?
          end

          def column(node) = (Tree.qualified(node.column_ref) if node.node == :column_ref)
        end
      end
    end
  end
end
