# frozen_string_literal: true

require "pg_query"
require_relative "node_rewrite"

module Quaack
  module Enclave
    # Folds each column compared with true or false to the bare test, the
    # way the planner does: deleted = true and deleted <> false become
    # deleted, and active = false and active <> true become NOT active, on
    # either side of the operator. pg_get_indexdef keeps an existing index's
    # WHERE (deleted = true) as written, so IndexSql folds every predicate
    # this way, and it then matches a candidate's WHERE deleted.
    #
    # Only a bare column and a bare true or false fold. 't'::boolean
    # doesn't round-trip through pg_query anyway, and an expression such as
    # (a > 1) = true stays as written. It's private to the enclave namespace.
    module BooleanFold
      module_function

      # The node with every such comparison folded. It changes the node in
      # place, and may return another one. The holder lets NodeRewrite swap
      # the node itself.
      def fold(node)
        holder = PgQuery::SelectStmt.new(where_clause: node)
        NodeRewrite.each(holder) { |child| folded(child) }
        holder.where_clause
      end

      # What equality each operator tests: = true, <> false.
      OPERATORS = { "=" => true, "<>" => false }.freeze

      # The bare test for one comparison, or nil.
      def folded(node)
        equal = operator(node.a_expr)
        return if equal.nil?

        column, value = sides(node.a_expr)
        return unless column

        value.a_const.boolval.boolval == equal ? column : negated(column)
      end

      # true for =, false for <>, nil for anything else.
      def operator(expr)
        return unless expr&.kind == :AEXPR_OP && expr.name.size == 1

        OPERATORS[expr.name.first.string&.sval]
      end

      # The column and the boolean constant, in that order, or nil.
      def sides(expr)
        [[expr.lexpr, expr.rexpr], [expr.rexpr, expr.lexpr]].find do |column, value|
          column.column_ref && value.a_const&.boolval
        end
      end

      def negated(column) = PgQuery::Node.new(bool_expr: PgQuery::BoolExpr.new(boolop: :NOT_EXPR, args: [column]))
    end

    private_constant :BooleanFold
  end
end
