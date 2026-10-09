# frozen_string_literal: true

require "pg_query"
require_relative "deparse"

module Quaack
  module Enclave
    # Sorts the operands of each AND and each OR in a predicate by their
    # deparsed text, so two predicates that differ only in the order of their
    # conditions read the same. It works on pg_query's tree and never moves
    # an operand out of its own BoolExpr, except to lift a nested AND inside
    # an AND (or OR inside an OR) up a level, so precedence is kept. It only
    # looks inside BoolExprs (AND, OR, NOT), the one place order is free.
    # An operand the deparser can't write back leaves its BoolExpr as written.
    # It's private to the enclave namespace.
    module PredicateSort
      module_function

      # The node with every AND and OR sorted. It changes the node in place.
      def sort(node)
        bool = node.bool_expr
        return node unless bool

        bool.args.each { |arg| sort(arg) }
        return node if bool.boolop == :NOT_EXPR

        sorted = flattened(bool).sort_by { |arg| Deparse.expression(arg) }
        bool.args.replace(sorted)
        node
      rescue Deparse::Error
        node
      end

      # The operands of an AND or OR, with a nested AND inside an AND (or OR
      # inside an OR) replaced by its own operands, since pg_query keeps
      # c AND (b AND a) nested and the order is free across both levels.
      def flattened(bool)
        bool.args.flat_map do |arg|
          inner = arg.bool_expr
          inner && inner.boolop == bool.boolop ? inner.args.to_a : [arg]
        end
      end
    end

    private_constant :PredicateSort
  end
end
