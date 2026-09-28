# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "../supported_sql"
require_relative "literal"
require_relative "surroundings"
require_relative "sharing"

module Quaack
  module Enclave
    module Redaction
      # Replaces each constant in the query's parse with a numbered $n
      # placeholder (DESIGN.md 3g), and says what each one stood for. See
      # Redaction.query.
      class Query
        # EXTRACT's fields that Postgres documents. PredicateAtoms keeps the
        # same ones (see its Literals).
        EXTRACT_FIELDS = %w[
          century day decade dow doy epoch hour isodow isoyear julian microseconds millennium milliseconds minute
          month quarter second timezone timezone_hour timezone_minute week year
        ].to_set.freeze

        # The typmod pg_query gives an interval with no field qualifier.
        INTERVAL_FULL_RANGE = 0x7FFF

        # Deparse allows this depth, so the copy should too.
        DEPTH = Deparse::DEPTH

        attr_reader :tree, :placeholders

        def initialize(parse)
          SupportedSql.check!(parse)
          raise Error, "query_has_parameters" if parameters?(parse)

          @surroundings = Surroundings.new
          @found = {}
          @tree = copy(parse.tree)
          replace
          @placeholders = @representatives.map { |location| placeholder(location, @numbers.fetch(location)) }.freeze
        end

        private

        # Numbers each constant the first walk finds by its place in the
        # text, then walks again to replace them.
        def replace
          @notes = []
          visit(@tree)
          @numbers = numbers
          @replacing = true
          visit(@tree)
        end

        # Each constant's number: its representative's place in the text,
        # among the representatives (see Sharing).
        def numbers
          sharing = Sharing.new(@found)
          @notes.each { sharing.note(it) }
          @representatives = @found.keys.select { sharing.representative(it) == it }.sort
          ranks = @representatives.each_with_index.to_h { |location, i| [location, i + 1] }
          @found.keys.to_h { [it, ranks.fetch(sharing.representative(it))] }
        end

        def parameters?(parse)
          found = false
          parse.walk! { |_parent, _field, node, _location| found ||= node.is_a?(PgQuery::ParamRef) }
          found
        end

        def copy(tree) = tree.class.decode(tree.class.encode(tree, recursion_limit: DEPTH), recursion_limit: DEPTH)

        # Walks every message under this one. The first walk finds the
        # constants and what surrounds them. The second, once each has its
        # number, swaps them for placeholders. A type's name and modifiers
        # are shape, so the walk skips them.
        def visit(message)
          return if message.is_a?(PgQuery::TypeName)

          unless @replacing
            @surroundings.note(message)
            @notes << message if message.is_a?(PgQuery::SelectStmt) || message.is_a?(PgQuery::FuncCall)
          end
          message.class.descriptor.each { |field| visit_field(message, field) if field.type == :message }
        end

        def visit_field(message, field)
          value = field.get(message)
          if field.label == :repeated
            value.each_with_index { |node, i| value[i] = child(message, field.name, node, i) }
          elsif value
            replaced = child(message, field.name, value, 0)
            field.set(message, replaced) unless replaced.equal?(value)
          end
        end

        # The node to keep in the parent's field: the node itself, or, on
        # the second walk, the placeholder for a constant.
        def child(parent, field, node, index)
          return node.tap { visit(node) } unless node.is_a?(PgQuery::Node)

          constant = node.a_const
          return node.tap { visit(node.inner) if walked?(parent, field, node) } unless constant
          return node if kept?(parent, field, constant, index)
          return param(constant) if @replacing

          found(constant, (parent.type_name if parent.is_a?(PgQuery::TypeCast)))
          node
        end

        # Whether the walk goes into a node that isn't a constant: not into
        # an empty slot, such as a function's missing column definitions in
        # FROM, or a positional ORDER BY.
        def walked?(parent, field, node) = !node.node.nil? && !positional?(parent, field, node)

        def found(constant, cast)
          raise Error, "interval_field_qualifier" if field_qualified?(cast)

          @found[constant.location] = [constant, cast]
        end

        # An interval cast with a field qualifier, such as INTERVAL '1' DAY.
        # The qualifier changes how the literal reads: '1' is a day there,
        # but a bound $1 reads as an interval first, so it's a second, and
        # then 0 days. PREPARE can't declare the qualifier, and keeping the
        # literal would let it leave, so the query is refused. A precision
        # alone, as in INTERVAL(3), reads the same either way.
        def field_qualified?(cast)
          return false unless cast && Literal.type_name(cast) == "interval"

          mask = cast.typmods.first&.a_const
          !mask.nil? && mask.ival&.ival != INTERVAL_FULL_RANGE
        end

        # ORDER BY 1 names the first output column, and so do GROUP BY 1 and
        # DISTINCT ON (1). A $n there would sort by a constant instead.
        def positional?(parent, field, node)
          parent.is_a?(PgQuery::SelectStmt) && field == "sort_clause" && !node.sort_by&.node&.a_const.nil?
        end

        def kept?(parent, field, constant, index)
          constant.location == -1 ||
            (parent.is_a?(PgQuery::SelectStmt) && %w[group_clause distinct_clause].include?(field)) ||
            (field == "args" && index.zero? && extract?(parent) && extract_field?(constant))
        end

        def extract?(node)
          node.is_a?(PgQuery::FuncCall) && node.funcformat == :COERCE_SQL_SYNTAX && node.args.size == 2 &&
            node.funcname.map { |part| part.string.sval } == %w[pg_catalog extract]
        end

        def extract_field?(constant) = EXTRACT_FIELDS.include?(constant.sval&.sval.to_s.downcase)

        def param(constant)
          PgQuery::Node.new(param_ref: PgQuery::ParamRef.new(number: @numbers.fetch(constant.location)))
        end

        def placeholder(location, number)
          constant, cast = @found.fetch(location)
          value, type = Literal.of(constant)
          Placeholder.new(number:, value:, type:, shape: @surroundings.shape(constant, cast))
        end
      end

      private_constant :Query
    end
  end
end
