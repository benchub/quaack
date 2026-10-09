# frozen_string_literal: true

require "pg_query"
require_relative "deparse"

module Quaack
  module Enclave
    # Sorts the operands of each AND and each OR in a predicate by their
    # deparsed text, so two predicates that differ only in the order of their
    # conditions read the same. It works on pg_query's tree and never moves
    # an operand out of its own BoolExpr, so precedence is kept. It only
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

        sorted = bool.args.to_a.sort_by { |arg| Deparse.expression(arg) }
        bool.args.replace(sorted)
        node
      rescue Deparse::Error
        node
      end
    end

    private_constant :PredicateSort
  end
end
