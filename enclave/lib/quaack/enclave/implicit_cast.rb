# frozen_string_literal: true

require "pg_query"
require_relative "node_rewrite"

module Quaack
  module Enclave
    # Drops the implicit casts pg_get_indexdef prints in an existing index's
    # predicate. Postgres reads varchar_col = 'x' as (varchar_col)::text =
    # 'x'::text, since varchar has no operators of its own. A candidate
    # written as the user wrote it has no casts, so without this the two
    # never match. It's private to the enclave namespace.
    #
    # Only one shape goes: a bare column cast to text, where the column's
    # type is varchar or text, compared with =, <>, <, >, <=, or >=, or
    # tested with IN against string constants cast to text. For those, the
    # cast changes nothing: the comparison runs on text with the column's
    # own collation either way. Every other cast stays, because it may
    # change meaning: an int column cast to text compares as text, a cast
    # to varchar(3) truncates, and a COLLATE clause changes the collation.
    # With no column type known, nothing is dropped.
    module ImplicitCast
      module_function

      COMPARISONS = %w[= <> < > <= >=].freeze
      ARRAY_FORMS = [[:AEXPR_OP_ANY, "="], [:AEXPR_OP_ALL, "<>"]].freeze
      PLAIN_TYPES = %w[varchar text].freeze

      # The node with those casts dropped, in place. It may return another
      # node. column_types maps a column name to its type's name, as
      # PlannerStatistics's column_types does.
      def strip(node, column_types)
        return node if node.nil? || column_types.empty?

        holder = PgQuery::SelectStmt.new(where_clause: node)
        NodeRewrite.each(holder) { |child| stripped(child, column_types) }
        holder.where_clause
      end

      # Returns the same node, changed, or nil to walk on.
      def stripped(node, column_types)
        expr = node.a_expr
        return unless expr

        case expr.kind
        when :AEXPR_OP then strip_comparison(node, expr, column_types)
        when :AEXPR_OP_ANY, :AEXPR_OP_ALL then strip_array(node, expr, column_types)
        end
      end

      def strip_comparison(node, expr, column_types)
        return unless COMPARISONS.include?(operator_name(expr))

        column = plain_column(expr.lexpr, column_types)
        return unless column && (value = bare_text_const(expr.rexpr))

        expr.lexpr = column
        expr.rexpr = value
        node
      end

      # col = ANY (ARRAY[...]) is IN, and col <> ALL (ARRAY[...]) is NOT IN.
      # Postgres prints the array as ((ARRAY['a'::varchar])::text[]) for a
      # varchar column. It becomes the list the user wrote, so the IN
      # deparses as the candidate's does.
      def strip_array(node, expr, column_types)
        return unless ARRAY_FORMS.include?([expr.kind, operator_name(expr)])

        column = plain_column(expr.lexpr, column_types)
        consts = column && array_consts(expr.rexpr)
        return unless consts

        expr.kind = :AEXPR_IN
        expr.lexpr = column
        expr.rexpr = PgQuery::Node.new(list: PgQuery::List.new(items: consts))
        node
      end

      def operator_name(expr) = (expr.name.first.string&.sval if expr.name.size == 1)

      # The string constants of the array node, or nil if any is something else.
      def array_consts(node)
        consts = array_of(node)&.elements&.map { text_const(it) }
        consts if consts&.any? && consts.all?
      end

      def array_of(node)
        node = node.type_cast.arg if node.type_cast && text_type?(node.type_cast.type_name, array: true)
        node.a_array_expr
      end

      # The bare column node when node is a text or varchar column, bare or
      # cast to text.
      def plain_column(node, column_types)
        cast = node.type_cast
        column = cast && text_type?(cast.type_name) ? cast.arg : node
        name = column_name(column)
        column if name && PLAIN_TYPES.include?(column_types[name])
      end

      # The name of a one-part column reference, or nil.
      def column_name(node)
        fields = node.column_ref&.fields
        fields.first.string&.sval if fields&.size == 1
      end

      # The string constant when node is 'lit'::text, or already bare.
      def bare_text_const(node)
        cast = node.type_cast
        return cast.arg if cast && text_type?(cast.type_name) && cast.arg.a_const&.sval

        nil
      end

      # The string constant when node is 'lit'::text or 'lit'::varchar.
      def text_const(node)
        cast = node.type_cast
        cast.arg if cast && text_type?(cast.type_name, kinds: PLAIN_TYPES) && cast.arg.a_const&.sval
      end

      def text_type?(type, kinds: ["text"], array: false)
        names = type.names.map { it.string&.sval } - ["pg_catalog"]
        names.size == 1 && kinds.include?(names.first) && type.typmods.empty? && type.array_bounds.any? == array
      end
    end

    private_constant :ImplicitCast
  end
end
