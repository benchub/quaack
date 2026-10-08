# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class OrToUnion
        # Which of a SELECT's conditions are ORs worth splitting, and how.
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
        # - No arm can raise on some rows (see raises?).
        #
        # Arms.groups gives the OR's arms in the groups that each become
        # one branch of the UNION: arms with no subquery that read the same
        # tables stay together, as an OR in their order, and every other
        # arm is a group of its own.
        module Arms
          # Comparisons, which give true, false, or NULL for any two values
          # of the built-in types QUAACK sees.
          COMPARISONS = %w[= <> != < <= > >=].freeze
          OPERATOR_KINDS = %i[AEXPR_OP AEXPR_OP_ANY AEXPR_OP_ALL].freeze
          SAFE_KINDS = %i[AEXPR_IN AEXPR_LIKE AEXPR_ILIKE AEXPR_DISTINCT AEXPR_NOT_DISTINCT AEXPR_NULLIF
                          AEXPR_BETWEEN AEXPR_NOT_BETWEEN AEXPR_BETWEEN_SYM AEXPR_NOT_BETWEEN_SYM].freeze
          SAFE_SUBLINKS = %i[EXISTS_SUBLINK ANY_SUBLINK ALL_SUBLINK].freeze

          module_function

          def splittable(select)
            names = Tree.from_items(select.from_clause).map(&:name)
            conditions = Tree.conjuncts(select.where_clause)
            conditions.each_index.select { split?(conditions[it], names) }
          end

          def split?(condition, names)
            return false unless condition.node == :bool_expr && condition.bool_expr.boolop == :OR_EXPR

            arms = condition.bool_expr.args.map { reads(it, names) }
            arms.all? && (arms.any?(&:last) || arms.uniq.size > 1) && !raises?(condition)
          end

          # The OR's arm indexes, in groups (see above), in the order each
          # group's first arm comes.
          def groups(condition)
            keys = condition.bool_expr.args.each_with_index.map do |arm, index|
              Tree.find(arm, PgQuery::SubLink).any? ? index : outer_columns(arm).to_set { Tree.qualified(it).first }
            end
            keys.each_index.group_by { keys[it] }.values
          end

          # [the tables arm reads outside its subqueries, whether it has a
          # subquery], or nil if it reads nothing, or a column isn't
          # written name.column of a FROM table.
          def reads(arm, names)
            tables = outer_columns(arm).map { Tree.qualified(it)&.first }.uniq
            subquery = Tree.find(arm, PgQuery::SubLink).any?
            [tables.sort, subquery] if (tables - names).empty? && (subquery || tables.any?)
          end

          # Whether node, subqueries included, holds an expression that can
          # raise an error for some values of a column in it: a cast, a
          # function call, an operator other than a comparison (such as /
          # or %), an index or field of a value, or a subquery used as a
          # value, which raises when it gives more than one row. Postgres
          # runs an OR's arms in order and stops at the first true one, so
          # an earlier arm can keep a later one from running on the rows
          # where it would raise. Split, every arm runs on its own, so the
          # rule leaves these alone. One with no column in it gives the
          # same value on every row, so it raises in the original too.
          def raises?(node)
            all_nodes(node).any? do |inner|
              case inner
              when PgQuery::SubLink then !SAFE_SUBLINKS.include?(inner.sub_link_type)
              when PgQuery::TypeCast, PgQuery::FuncCall, PgQuery::A_Indirection then columns?(inner)
              when PgQuery::A_Expr then !safe?(inner) && columns?(inner)
              else false
              end
            end
          end

          def safe?(expr)
            return SAFE_KINDS.include?(expr.kind) unless OPERATOR_KINDS.include?(expr.kind)

            expr.name.size == 1 && COMPARISONS.include?(expr.name.first.string.sval)
          end

          def columns?(node) = !Tree.find(node, PgQuery::ColumnRef).empty?

          # Every message in node, itself included, at any depth.
          def all_nodes(node, found = [])
            case node
            when Google::Protobuf::RepeatedField then node.each { all_nodes(it, found) }
            when PgQuery::Node then all_nodes(node.inner, found)
            when Google::Protobuf::MessageExts
              found << node
              node.class.descriptor.each { all_nodes(it.get(node), found) }
            end
            found
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
