# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class OrToUnion
        # Which of a SELECT's conditions are ORs worth splitting.
        #
        # Arms.splittable gives the index, among the conditions the WHERE
        # ANDs together, of each OR that meets all of this:
        #
        # - Outside its subquery expressions, every column in every arm is
        #   written name.column, where name is a FROM table.
        # - Each arm reads a table or has a subquery.
        # - The arms differ: one has a subquery, or two read different sets
        #   of tables. An OR on one table is left alone, since the planner
        #   handles it with a BitmapOr.
        module Arms
          module_function

          def splittable(select)
            names = Tree.from_items(select.from_clause).map(&:name)
            conditions = Tree.conjuncts(select.where_clause)
            conditions.each_index.select { split?(conditions[it], names) }
          end

          def split?(condition, names)
            return false unless condition.node == :bool_expr && condition.bool_expr.boolop == :OR_EXPR

            arms = condition.bool_expr.args.map { reads(it, names) }
            arms.all? && (arms.any?(&:last) || arms.uniq.size > 1)
          end

          # [the tables arm reads outside its subqueries, whether it has a
          # subquery], or nil if it reads nothing, or a column isn't
          # written name.column of a FROM table.
          def reads(arm, names)
            tables = outer_columns(arm).map { Tree.qualified(it)&.first }.uniq
            subquery = Tree.find(arm, PgQuery::SubLink).any?
            [tables.sort, subquery] if (tables - names).empty? && (subquery || tables.any?)
          end

          # Every ColumnRef in node that isn't part of a subquery
          # expression, such as x IN (SELECT ...), whose x is left out too.
          def outer_columns(node, found = [])
            return found if node.is_a?(PgQuery::SubLink)

            case node
            when PgQuery::ColumnRef then found << node
            when Google::Protobuf::RepeatedField then node.each { outer_columns(it, found) }
            when PgQuery::Node then outer_columns(node.inner, found)
            when Google::Protobuf::MessageExts then node.class.descriptor.each { outer_columns(it.get(node), found) }
            end
            found
          end
        end
      end
    end
  end
end
