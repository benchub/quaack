# frozen_string_literal: true

require "json"
require_relative "tree"
require_relative "combination"

module Quaack
  module Enclave
    module Fuzz
      # What WorldValues and the copies generator read from the two queries'
      # parse trees (tree.to_h): their constants by kind, the separators a
      # split_part or LIKE uses, the keys a JSON operator reads, the columns
      # a query divides by, whether it casts to a small integer type, the
      # columns it groups or partitions on, and each column it combines with
      # a number and compares with another (combinations).
      #
      #   facts = Facts.new(trees)
      #   facts.integers     # => [5, 2025]
      #   facts.separators   # => ["@"]
      #
      # Trust boundary: these are the queries' constants, so they stay in
      # the enclave.
      class Facts
        JSON_OPERATORS = %w[-> ->> ? #> #>>].freeze
        DIVIDES = %w[/ %].freeze
        SMALL_INTEGERS = { "int2" => 16, "smallint" => 16, "int4" => 32, "integer" => 32, "int" => 32 }.freeze
        LIKE = %i[AEXPR_LIKE AEXPR_ILIKE].freeze
        VISITS = { a_const: :constant, a_expr: :a_expr, func_call: :function, type_cast: :cast }.freeze
        COMPARES = %w[= <> < <= > >=].freeze
        BETWEENS = %i[AEXPR_BETWEEN AEXPR_NOT_BETWEEN AEXPR_BETWEEN_SYM AEXPR_NOT_BETWEEN_SYM].freeze

        attr_reader :strings, :integers, :numbers, :separators, :like_patterns, :json_keys, :json_leaves,
                    :divided, :int_casts, :grouped, :combinations

        def initialize(trees)
          @strings, @numbers, @separators, @like_patterns, @json_keys, @json_leaves, @combinations = Array.new(7) { [] }
          @divided, @int_casts, @grouped = Array.new(3) { Set.new }
          trees.each { walk(it) }
          @integers = @numbers.filter_map { Integer(it, exception: false) }.uniq
          json_constants
          [@strings, @numbers, @separators, @like_patterns, @json_keys, @json_leaves].each(&:uniq!)
        end

        private

        def walk(node)
          case node
          when Hash
            visit(node)
            node.each_value { walk(it) }
          when Array then node.each { walk(it) }
          end
        end

        def visit(node)
          VISITS.each { |key, visit| send(visit, node[key]) if node[key] }
          %i[group_clause partition_clause].each { @grouped.merge(Tree.column_refs(node[it])) if node[it] }
        end

        def constant(const)
          return if const[:isnull]

          if (sval = const.dig(:sval, :sval))
            @strings << sval
          else
            @numbers << Tree.value(const)
          end
        end

        def a_expr(expr)
          name = expr[:name]&.last&.dig(:string, :sval)
          @divided.merge(Tree.column_refs(expr[:rexpr])) if DIVIDES.include?(name)
          compared(expr, name)
          right = string(expr[:rexpr])
          return unless right

          like(right) if like?(expr[:kind], name)
          @json_keys << right if JSON_OPERATORS.include?(name)
        end

        def compared(expr, name)
          if expr[:kind] == :AEXPR_OP && COMPARES.include?(name)
            [%i[lexpr rexpr], %i[rexpr lexpr]].each { |side, other| combined(expr[side], expr[other]) }
          elsif BETWEENS.include?(expr[:kind])
            expr.dig(:rexpr, :list, :items)&.each { combined(expr[:lexpr], it) }
          end
        end

        def combined(node, other)
          combination = Combination.of(node, Combination.number(other))
          @combinations << combination if combination
        end

        def like?(kind, name) = LIKE.include?(kind) || %w[~~ ~~*].include?(name)

        def like(pattern)
          @like_patterns << pattern
          @separators.concat(pattern.delete("%_\\").chars.grep(/[^[:alnum:][:space:]]/))
        end

        def function(call)
          name = call[:funcname]&.last&.dig(:string, :sval)
          delimiter = string(call[:args]&.at(1))
          @separators << delimiter if name == "split_part" && delimiter && !delimiter.empty?
        end

        def cast(cast)
          bits = SMALL_INTEGERS[cast.dig(:type_name, :names)&.last&.dig(:string, :sval)]
          @int_casts << bits if bits && !cast.dig(:type_name, :array_bounds)
        end

        def string(node) = node.is_a?(Hash) ? node.dig(:a_const, :sval, :sval) : nil

        # The keys and leaf values of each string constant that's a JSON
        # object or array.
        def json_constants
          @strings.each do |text|
            next unless text.start_with?("{", "[")

            json(JSON.parse(text))
          rescue JSON::ParserError
            nil
          end
        end

        def json(value)
          case value
          when Hash
            @json_keys.concat(value.keys)
            value.each_value { json(it) }
          when Array then value.each { json(it) }
          when nil then nil
          else @json_leaves << value
          end
        end
      end
    end
  end
end
