# frozen_string_literal: true

require "pg_query"
require_relative "index_sql"

module Quaack
  module Enclave
    # The SQL behind one index key column (IndexCandidate::KeyColumn): its
    # expression, its opclass and collation, and its IndexElem node. It's
    # private to the enclave namespace. Use IndexCandidate instead.
    #
    # An expression can hold a literal, so no error raised here quotes it.
    module IndexKeySql
      module_function

      # A KeyColumn's name and expression, from what it was given: exactly
      # one of them.
      def column_or_expression(name, expression)
        if name.nil? == expression.nil?
          raise IndexCandidateError, "a key column needs a name or an expression, not both"
        end

        return [column_name(name), nil] if expression.nil?

        normalize_expression(expression)
      end

      # See KeyColumn. Returns [name, nil] for an expression that's only a
      # column, and [nil, expression] otherwise.
      def normalize_expression(sql)
        raise IndexCandidateError, "key expression must be SQL text" unless sql.is_a?(String)

        node = IndexSql.parse_predicate(sql, what: "key expression")
        column = bare_column(node)
        column ? [column, nil] : [nil, IndexSql.deparse_predicate(node, what: "key expression").freeze]
      end

      # A plain column name, as a frozen copy.
      def column_name(name)
        return name.dup.freeze if name.is_a?(String) && !name.empty?

        raise IndexCandidateError, "column name must be a non-empty String, got #{name.inspect}"
      end

      # See KeyColumn: a name, or its parts, with any pg_catalog in front
      # dropped, as a frozen Array. nil stays nil.
      def qualified_name(what, value)
        return nil if value.nil?

        parts = value.is_a?(String) ? [value] : value
        unless name_parts?(parts)
          raise IndexCandidateError, "#{what} must be a name or an Array of name parts, got #{value.inspect}"
        end

        parts = parts.drop(1) if parts.size > 1 && parts.first == "pg_catalog"
        parts.map { |p| p.dup.freeze }.freeze
      end

      def name_parts?(parts) = parts.is_a?(Array) && !parts.empty? && parts.all? { |p| p.is_a?(String) && !p.empty? }

      # One KeyColumn as an IndexElem node. Leaves out whatever matches
      # Postgres's defaults, so the DDL reads the way a person would write it.
      def index_elem(key)
        expr = key.expression && IndexSql.parse_predicate(key.expression, what: "key expression")
        PgQuery::Node.new(index_elem: PgQuery::IndexElem.new(
          name: key.name || "", expr:,
          opclass: name_nodes(key.opclass), collation: name_nodes(key.collation),
          ordering: key.direction == :desc ? :SORTBY_DESC : :SORTBY_DEFAULT, nulls_ordering: nulls_ordering(key)
        ))
      end

      def nulls_ordering(key)
        if key.nulls == IndexCandidate::KeyColumn::DEFAULT_NULLS.fetch(key.direction)
          :SORTBY_NULLS_DEFAULT
        else
          key.nulls == :first ? :SORTBY_NULLS_FIRST : :SORTBY_NULLS_LAST
        end
      end

      def name_nodes(parts) = (parts || []).map { |p| PgQuery::Node.new(string: PgQuery::String.new(sval: p)) }

      # A parsed IndexElem as a KeyColumn. An opclass's parameters are left
      # out, so IndexSql.read_index gives nil for them.
      def key_column(elem)
        IndexCandidate::KeyColumn.new(
          **column_of(elem),
          direction: elem.ordering == :SORTBY_DESC ? :desc : :asc,
          nulls: { SORTBY_NULLS_FIRST: :first, SORTBY_NULLS_LAST: :last }[elem.nulls_ordering],
          opclass: parts(elem.opclass), collation: parts(elem.collation)
        )
      end

      def column_of(elem)
        return { name: elem.name } unless elem.expr

        { expression: IndexSql.deparse_predicate(elem.expr, what: "key expression") }
      end

      def parts(nodes) = (nodes.map { |n| n.string.sval } unless nodes.empty?)

      # Changes a parsed IndexElem in place to what index_elem would render
      # for the KeyColumn key_column reads from it: ASC or a default nulls
      # ordering left implicit, an expression that's only a column as that
      # column, and no pg_catalog in front of an opclass or collation.
      def comparable(elem)
        comparable_order(elem)
        if elem.expr && (column = bare_column(elem.expr))
          elem.name = column
          elem.expr = nil
        end
        [elem.opclass, elem.collation].each do |names|
          names.shift if names.size > 1 && names.first.string&.sval == "pg_catalog"
        end
      end

      def comparable_order(elem)
        elem.ordering = :SORTBY_DEFAULT if elem.ordering == :SORTBY_ASC
        default_nulls = elem.ordering == :SORTBY_DESC ? :SORTBY_NULLS_FIRST : :SORTBY_NULLS_LAST
        elem.nulls_ordering = :SORTBY_NULLS_DEFAULT if elem.nulls_ordering == default_nulls
      end

      def bare_column(node)
        fields = node.column_ref&.fields
        fields.first.string.sval.dup.freeze if fields&.size == 1
      end
    end

    private_constant :IndexKeySql
  end
end
