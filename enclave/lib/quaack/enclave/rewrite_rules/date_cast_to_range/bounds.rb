# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class DateCastToRange
        # The range's bounds, written as conjuncts on the column.
        module Bounds
          module_function

          # column op day, or column op day + 1 for a bound of :next, or nil
          # for no bound. bound is [:day or :next, the day's Node].
          def bound(operator, column, bound)
            return unless bound

            kind, node = bound
            day = date(node)
            day = plus_one(day) if kind == :next
            column = PgQuery::Node.new(column_ref: PgQuery::ColumnRef.decode(PgQuery::ColumnRef.encode(column)))
            PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind: :AEXPR_OP, name: [Tree.string(operator)],
                                                          lexpr: column, rexpr: day))
          end

          # A copy of the placeholder, cast to date: of node, if it's that
          # already.
          def date(node)
            copy = PgQuery::Node.decode(PgQuery::Node.encode(node))
            return copy if node.node == :type_cast

            cast = Tree.where_of("SELECT WHERE $1::date").type_cast
            cast.arg = copy
            PgQuery::Node.new(type_cast: cast)
          end

          def plus_one(day)
            sum = Tree.where_of("SELECT WHERE $1 + 1").a_expr
            sum.lexpr = day
            PgQuery::Node.new(a_expr: sum)
          end
        end
      end
    end
  end
end
