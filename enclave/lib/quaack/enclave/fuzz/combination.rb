# frozen_string_literal: true

require_relative "tree"

module Quaack
  module Enclave
    module Fuzz
      # A column combined with a number and compared with another, such as
      # 100 / points > 2: column "points", operator "/", constant "100",
      # column_first false, compared "2". Facts finds them.
      #
      #   Combination.of(node, "2")  # => a Combination, or nil
      Combination = Data.define(:column, :operator, :constant, :column_first, :compared)

      class Combination
        ARITHMETIC = %w[+ - * /].freeze

        # node's Combination with compared, if node (a tree.to_h node) is a
        # column and a number joined by + - * or /, and compared is a
        # number.
        def self.of(node, compared)
          arithmetic = node.is_a?(Hash) && node[:a_expr]
          return unless compared && arithmetic && arithmetic[:kind] == :AEXPR_OP

          operator = arithmetic[:name].last.dig(:string, :sval)
          paired(operator, *arithmetic.values_at(:lexpr, :rexpr), compared) if ARITHMETIC.include?(operator)
        end

        def self.paired(operator, left, right, compared)
          if column(left) && number(right)
            new(column(left), operator, number(right), true, compared)
          elsif number(left) && column(right)
            new(column(right), operator, number(left), false, compared)
          end
        end

        def self.column(node) = node.is_a?(Hash) ? node.dig(:column_ref, :fields)&.last&.dig(:string, :sval) : nil

        # node's value as text if it's a number constant, else nil.
        def self.number(node) = node.is_a?(Hash) && node[:a_const] ? Tree.value(node[:a_const]) : nil
      end
    end
  end
end
