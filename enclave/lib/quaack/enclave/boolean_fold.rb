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

      # The node with every such comparison folded, and every double NOT
      # collapsed (NOT (f = false) is NOT NOT f, which is f). A fold can
      # make another one possible, as in (f = true) = true, so it repeats
      # until a pass changes nothing, which makes folding idempotent. It
      # changes the node in place, and may return another one. The holder
      # lets NodeRewrite swap the node itself.
      def fold(node)
        holder = PgQuery::SelectStmt.new(where_clause: node)
        loop do
          before = PgQuery::Node.encode(holder.where_clause)
          NodeRewrite.each(holder) { |child| folded(child) }
          return holder.where_clause if PgQuery::Node.encode(holder.where_clause) == before
        end
      end

      # What equality each operator tests: = true, <> false.
      OPERATORS = { "=" => true, "<>" => false }.freeze

      # The bare test for one comparison, or nil.
      def folded(node)
        return double_not(node) if node.node == :bool_expr

        equal = operator(node.a_expr)
        return if equal.nil?

        column, value = sides(node.a_expr)
        return unless column

        value.a_const.boolval.boolval == equal ? column : negated(column)
      end

      # NOT NOT x is x, in three-valued logic too. Any other boolean
      # expression is left alone, and its children walked.
      def double_not(node)
        arg = not_arg(node.bool_expr)
        not_arg(arg.bool_expr) if arg
      end

      # The one argument of a NOT, or nil for anything else.
      def not_arg(expr)
        expr.args.first if expr&.boolop == :NOT_EXPR && expr.args.size == 1
      end

      # true for =, false for <>, nil for anything else.
      def operator(expr)
        return unless expr&.kind == :AEXPR_OP

        # An operator written with its schema, OPERATOR(pg_catalog.=), has
        # the schema first, so it never matches.
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
