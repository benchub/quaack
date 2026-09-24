# frozen_string_literal: true

require "pg_query"
require_relative "../pg_array"
require_relative "literal"

module Quaack
  module Enclave
    module Redaction
      # What surrounds each constant in the query, for its placeholder's
      # shape (see Placeholder): whether it's a LIKE pattern, and with what
      # escape character, and whether it's in an IN list, an ARRAY[...], or
      # the array of ANY or ALL. Constants are known by their location,
      # which is unique for every constant written in the query.
      class Surroundings
        LIKE_OPERATORS = %w[~~ ~~* !~~ !~~*].freeze
        LIKE_KINDS = %i[AEXPR_LIKE AEXPR_ILIKE AEXPR_OP].freeze

        def initialize
          @hints = Hash.new { |hash, location| hash[location] = {} }
        end

        # Records what this message says about the constants under it.
        def note(message)
          case message
          when PgQuery::A_Expr then expression(message)
          when PgQuery::A_ArrayExpr then list(message.elements)
          end
        end

        # What the placeholder for this constant looks like, never what it
        # holds. cast is the TypeName of the cast right around it, if any.
        def shape(constant, cast)
          hints = @hints.fetch(constant.location, {})
          text = constant.sval&.sval
          shape = { "type" => cast ? Literal.type_class(cast) : Literal.class_of(constant) }
          shape["pattern"] = Literal.pattern(text, hints[:like]) if hints[:like] && text
          elements = hints[:elements] || array_elements(text, cast, hints)
          shape["elements"] = elements if elements
          shape.freeze
        end

        private

        def array_elements(text, cast, hints)
          return unless text && (hints[:array] || cast&.array_bounds&.any?)

          PgArray.parse(text).size
        rescue ArgumentError
          nil
        end

        def expression(expr)
          like = LIKE_OPERATORS.include?(expr.name.map { |n| n.string.sval }.join("."))
          case expr.kind
          when :AEXPR_IN then in_list(expr.rexpr)
          when :AEXPR_OP_ANY, :AEXPR_OP_ALL then quantified(expr.rexpr, like)
          end
          pattern(expr.rexpr) if like && LIKE_KINDS.include?(expr.kind)
        end

        def in_list(rexpr) = rexpr&.list&.then { list(it.items) }

        def list(items) = items.each { |item| hint(item, elements: items.size) }

        def quantified(rexpr, like)
          return hint(rexpr, array: true) unless rexpr.a_array_expr

          rexpr.a_array_expr.elements.each { |e| pattern(e) } if like
        end

        # A LIKE pattern, written with or without ESCAPE, which the parser
        # makes a call to like_escape.
        def pattern(node)
          call = node&.func_call
          return hint(node, like: "\\") unless call
          return unless like_escape?(call)

          escape = uncast(call.args[1]).a_const&.sval
          hint(call.args[0], like: escape.sval) if escape
        end

        def like_escape?(call)
          call.funcname.map { |part| part.string.sval } == %w[pg_catalog like_escape] && call.args.size == 2
        end

        def hint(node, **hints)
          constant = uncast(node).a_const if node
          @hints[constant.location].merge!(hints) if constant
        end

        def uncast(node)
          node = node.type_cast.arg while node.type_cast
          node
        end
      end

      private_constant :Surroundings
    end
  end
end
