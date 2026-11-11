# frozen_string_literal: true

require_relative "tree"

module Quaack
  module Enclave
    module Fuzz
      # A column combined with a number and compared with another, such as
      # 100 / points > 2: column "points", operator "/", constant "100",
      # column_first false, compared "2". A cast on the column is looked
      # through, so points::numeric / 3 > 2 gives column "points". table
      # is the column's table (a TableName) where its qualifier names one,
      # else nil. Facts finds them.
      #
      #   Combination.of(node, "2") { |qualifier| table }  # => a Combination, or nil
      Combination = Data.define(:column, :operator, :constant, :column_first, :compared, :table)

      class Combination
        ARITHMETIC = %w[+ - * /].freeze

        # node's Combination with compared, if node (a tree.to_h node) is a
        # column and a number joined by + - * or /, and compared is a
        # number. The block gives the table for the column's qualifier,
        # its fields before the name, such as ["a"] for a.points.
        def self.of(node, compared, binding = nil, &table)
          arithmetic = node.is_a?(Hash) && node[:a_expr]
          return unless compared && arithmetic && arithmetic[:kind] == :AEXPR_OP

          operator = arithmetic[:name].last.dig(:string, :sval)
          return unless ARITHMETIC.include?(operator)

          paired(operator, *arithmetic.values_at(:lexpr, :rexpr), compared, table, binding)
        end

        def self.paired(operator, left, right, compared, table, binding) # rubocop:disable Metrics/ParameterLists
          column, constant, column_first = if column(left) && number(right, binding)
                                             [left, right, true]
                                           elsif number(left, binding) && column(right)
                                             [right, left, false]
                                           end
          return unless column

          fields = fields(column)
          new(column(column), operator, number(constant, binding), column_first, compared,
              table&.call(fields[0...-1].map { it.dig(:string, :sval) }))
        end

        # node's column name if it's a column, or a column under one or
        # more casts (points::numeric), else nil.
        def self.column(node) = fields(node)&.last&.dig(:string, :sval)

        def self.fields(node)
          return unless node.is_a?(Hash)
          return fields(node.dig(:type_cast, :arg)) if node[:type_cast]

          node.dig(:column_ref, :fields)
        end

        # node's value as text if it's a constant, a $n's from binding
        # (ConstantValue), else nil.
        def self.number(node, binding = nil) = ConstantValue.from_hash(node, binding)&.then { Tree.value(it) }
      end
    end
  end
end
