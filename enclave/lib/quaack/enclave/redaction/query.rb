# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "../pg_array"
require_relative "../supported_sql"
require_relative "literal"

module Quaack
  module Enclave
    module Redaction
      # Replaces each constant in the query's parse with a numbered $n
      # placeholder (README 3g), and says what each one stood for. See
      # Redaction.query.
      class Query
        LIKE_OPERATORS = %w[~~ ~~* !~~ !~~*].freeze

        # EXTRACT's fields that Postgres documents. PredicateAtoms keeps the
        # same ones (see its Literals).
        EXTRACT_FIELDS = %w[
          century day decade dow doy epoch hour isodow isoyear julian microseconds millennium milliseconds minute
          month quarter second timezone timezone_hour timezone_minute week year
        ].to_set.freeze

        # Deparse allows this depth, so the copy should too.
        DEPTH = Deparse::DEPTH

        attr_reader :tree, :placeholders

        def initialize(parse)
          SupportedSql.check!(parse)
          raise Error, "query_has_parameters" if parameters?(parse)

          @hints = Hash.new { |h, k| h[k] = {} }
          @found = {}
          @tree = copy(parse.tree)
          visit(@tree)
          @numbers = @found.keys.sort.each_with_index.to_h { |location, i| [location, i + 1] }
          @replacing = true
          visit(@tree)
          @placeholders = @numbers.map { |location, number| placeholder(location, number) }.freeze
        end

        private

        def parameters?(parse)
          found = false
          parse.walk! { |_parent, _field, node, _location| found ||= node.is_a?(PgQuery::ParamRef) }
          found
        end

        def copy(tree) = tree.class.decode(tree.class.encode(tree, recursion_limit: DEPTH), recursion_limit: DEPTH)

        # Walks every message under this one. The first walk finds the
        # constants and what surrounds them. The second, once each has its
        # number, swaps them for placeholders.
        def visit(message)
          return if message.is_a?(PgQuery::TypeName) # its modifiers are shape, and stay

          note(message)
          message.class.descriptor.each do |field|
            next unless field.type == :message

            value = field.get(message)
            if field.label == :repeated
              value.each_with_index { |child, i| value[i] = child(message, field.name, child, i) }
            elsif value
              replaced = child(message, field.name, value, 0)
              field.set(message, replaced) unless replaced.equal?(value)
            end
          end
        end

        # The node to keep in the parent's field: the node itself, or, on
        # the second walk, the placeholder for a constant.
        def child(parent, field, node, index)
          return node.tap { visit(node) } unless node.is_a?(PgQuery::Node)

          constant = node.a_const
          return node.tap { visit(node.inner) unless positional?(parent, field, node) } unless constant
          return node if kept?(parent, field, constant, index)
          return param(constant) if @replacing

          @found[constant.location] = [constant, (parent.type_name if parent.is_a?(PgQuery::TypeCast))]
          node
        end

        # ORDER BY 1 names the first output column, and so do GROUP BY 1 and
        # DISTINCT ON (1). A $n there would sort by a constant instead.
        def positional?(parent, field, node)
          parent.is_a?(PgQuery::SelectStmt) && field == "sort_clause" && !node.sort_by&.node&.a_const.nil?
        end

        def kept?(parent, field, constant, index)
          constant.location == -1 ||
            (parent.is_a?(PgQuery::SelectStmt) && %w[group_clause distinct_clause].include?(field)) ||
            (field == "args" && index.zero? && extract_field?(parent))
        end

        def extract_field?(node)
          node.is_a?(PgQuery::FuncCall) && node.funcformat == :COERCE_SQL_SYNTAX && node.args.size == 2 &&
            node.funcname.map { |part| part.string.sval } == %w[pg_catalog extract] &&
            EXTRACT_FIELDS.include?(node.args[0].a_const&.sval&.sval.to_s.downcase)
        end

        def param(constant)
          PgQuery::Node.new(param_ref: PgQuery::ParamRef.new(number: @numbers.fetch(constant.location)))
        end

        def placeholder(location, number)
          constant, cast = @found.fetch(location)
          value, type = Literal.of(constant)
          Placeholder.new(number:, value:, type:, shape: shape(constant, cast, @hints[location]))
        end

        # What the placeholder looks like, never what it holds.
        def shape(constant, cast, hints)
          shape = { "type" => cast ? Literal.type_class(cast) : Literal.class_of(constant) }
          pattern = hints[:like] && constant.sval && Literal.pattern(constant.sval.sval, hints[:like])
          shape["pattern"] = pattern if pattern
          elements = hints[:elements] || array_elements(constant, cast, hints)
          shape["elements"] = elements if elements
          shape.freeze
        end

        def array_elements(constant, cast, hints)
          return unless constant.sval && (hints[:array] || cast&.array_bounds&.any?)

          PgArray.parse(constant.sval.sval).size
        rescue ArgumentError
          nil
        end

        # Records what surrounds a constant, for its shape.
        def note(message)
          return if @replacing

          case message
          when PgQuery::A_Expr then note_expression(message)
          when PgQuery::A_ArrayExpr then list(message.elements)
          end
        end

        def note_expression(expr)
          operator = expr.name.map { |n| n.string.sval }.join(".")
          case expr.kind
          when :AEXPR_IN then list(expr.rexpr.list.items) if expr.rexpr&.list
          when :AEXPR_OP_ANY, :AEXPR_OP_ALL then quantified(expr.rexpr, operator)
          end
          like(expr.rexpr) if LIKE_OPERATORS.include?(operator) && %i[AEXPR_LIKE AEXPR_ILIKE AEXPR_OP].include?(expr.kind)
        end

        def list(items) = items.each { |item| hint(item, elements: items.size) }

        def quantified(rexpr, operator)
          return hint(rexpr, array: true) unless rexpr.a_array_expr

          rexpr.a_array_expr.elements.each { |e| like(e) } if LIKE_OPERATORS.include?(operator)
        end

        # A LIKE pattern, written with or without ESCAPE.
        def like(pattern)
          call = pattern&.func_call
          return hint(pattern, like: "\\") unless call

          name = call.funcname.map { |part| part.string.sval }
          return unless name == %w[pg_catalog like_escape] && call.args.size == 2

          escape = uncast(call.args[1]).a_const&.sval&.sval
          hint(call.args[0], like: escape) if escape
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

      private_constant :Query
    end
  end
end
