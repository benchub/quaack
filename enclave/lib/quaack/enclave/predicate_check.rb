# frozen_string_literal: true

require "pg_query"
require_relative "index_sql"

module Quaack
  module Enclave
    # What the 5a-3 filter (Dedupe) reads from a partial index predicate:
    # the columns it uses, and whether its constants are only ever compared
    # with a column. It's private to the enclave namespace. No error raised
    # here includes the predicate, which can hold real literals. Each
    # method raises what IndexSql.parse_predicate raises.
    module PredicateCheck
      module_function

      # The names of the columns a predicate uses, without repeats. A column
      # reference that isn't a bare name, such as t.a or t.*, comes back as
      # nil, since which column it means isn't certain.
      def predicate_columns(sql)
        IndexSql.parse_predicate(sql)
        names = []
        PgQuery.parse("SELECT WHERE #{sql}").walk! do |node|
          names << (node.fields.first.string&.sval if node.fields.size == 1) if node.is_a?(PgQuery::ColumnRef)
        end
        names.uniq
      end

      # The A_Expr kinds that compare one column with constants: col op
      # const, IS [NOT] DISTINCT FROM, [NOT] IN, = ANY or ALL, [NOT] BETWEEN
      # [SYMMETRIC], and [NOT] LIKE or ILIKE. Either side may be the column,
      # except in BETWEEN, where it must come first.
      COMPARISONS = %i[
        AEXPR_OP AEXPR_OP_ANY AEXPR_OP_ALL AEXPR_DISTINCT AEXPR_NOT_DISTINCT AEXPR_IN AEXPR_LIKE AEXPR_ILIKE
        AEXPR_BETWEEN AEXPR_NOT_BETWEEN AEXPR_BETWEEN_SYM AEXPR_NOT_BETWEEN_SYM
      ].to_set.freeze

      # Whether every constant in the predicate is compared directly with a
      # column reference, in one of the COMPARISONS: status = 'open',
      # 'open' = status, status IN ('a', 'b'), status = ANY('{a,b}'),
      # status = ANY(ARRAY['a']), status BETWEEN 'a' AND 'm'. Each constant
      # may be cast, but nothing else may wrap it, and the other side must be
      # the column itself, not an expression on it. A constant anywhere else,
      # such as in a function call ('bob' in lower('bob')), compared with
      # another constant, or standing alone (true), fails. So does a cast's
      # type modifier outside those comparisons (flag::varchar(10)). A
      # predicate with no constants passes.
      def constants_compared_with_columns?(sql) = !stray_constant?(IndexSql.parse_predicate(sql))

      def stray_constant?(node)
        node = unwrap(node)
        return true if node.is_a?(PgQuery::A_Const)
        return false if column_comparison?(node)

        children(node).any? { |child| stray_constant?(child) }
      end

      def column_comparison?(node)
        return false unless node.is_a?(PgQuery::A_Expr) && COMPARISONS.include?(node.kind)

        left = unwrap(node.lexpr)
        right = unwrap(node.rexpr)
        return left.is_a?(PgQuery::ColumnRef) && constant_list?(right) if node.kind.to_s.include?("BETWEEN")

        column_and_value?(left, right) || column_and_value?(right, left)
      end

      def column_and_value?(column, value)
        column.is_a?(PgQuery::ColumnRef) && (constant?(value) || constant_list?(value))
      end

      # A constant, a cast of one, or an ARRAY[...] of them.
      def constant?(node)
        case node = unwrap(node)
        when PgQuery::A_Const then true
        when PgQuery::TypeCast then constant?(node.arg)
        when PgQuery::A_ArrayExpr then node.elements.all? { |e| constant?(e) }
        else false
        end
      end

      # The list after IN, or BETWEEN's two bounds.
      def constant_list?(node) = node.is_a?(PgQuery::List) && node.items.all? { |item| constant?(item) }

      def unwrap(node) = node.is_a?(PgQuery::Node) ? node.public_send(node.node) : node

      def children(message)
        message.class.descriptor.flat_map do |field|
          value = field.get(message)
          value.is_a?(Google::Protobuf::RepeatedField) ? value.to_a : [value]
        end.grep(Google::Protobuf::MessageExts)
      end
    end

    private_constant :PredicateCheck
  end
end
