# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # The constant a node stands for: a literal's own A_Const, or, for a
    # $n, the A_Const its Binding's value and type would have been written
    # as (Redaction::Literal.of, the other way round). So an analysis that
    # reads constants from a parse tree gives the same answer on the $n
    # form, with its Binding, as on the literal form (task 20261110-12).
    # A $n with no binding, or past the binding's end, isn't a constant
    # it can read, so it's nil, as before.
    #
    #   ConstantValue.from_hash(node_hash, binding)  # => {ival: {ival: 5}} or nil  (tree.to_h nodes)
    #   ConstantValue.from_node(node, binding)       # => a PgQuery::A_Const or nil (protobuf nodes)
    #
    # Trust boundary: the values are the literals, so they stay in the
    # enclave, as the literals in the SQL did.
    module ConstantValue
      module_function

      def from_hash(node, binding = nil)
        return unless node.is_a?(Hash)
        return node[:a_const] if node[:a_const]

        number = node.dig(:param_ref, :number)
        number && const(binding, number)&.to_h
      end

      def from_node(node, binding = nil)
        return unless node.is_a?(PgQuery::Node)
        return node.a_const if node.a_const

        const(binding, node.param_ref.number) if node.param_ref
      end

      def const(binding, number)
        return unless binding && number.between?(1, binding.values.size)

        built(binding.values[number - 1], binding.types[number - 1])
      end

      def built(value, type)
        return PgQuery::A_Const.new(isnull: true) if value.nil?

        case type
        when "integer" then PgQuery::A_Const.new(ival: PgQuery::Integer.new(ival: Integer(value)))
        when "bigint", "numeric" then PgQuery::A_Const.new(fval: PgQuery::Float.new(fval: value))
        when "boolean" then PgQuery::A_Const.new(boolval: PgQuery::Boolean.new(boolval: value == "true"))
        when "bit varying" then PgQuery::A_Const.new(bsval: PgQuery::BitString.new(bsval: value))
        else PgQuery::A_Const.new(sval: PgQuery::String.new(sval: value))
        end
      end
    end
  end
end
