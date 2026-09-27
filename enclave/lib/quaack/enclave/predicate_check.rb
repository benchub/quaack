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
      # status = ANY(ARRAY['a']), status BETWEEN 'a' AND 'm'. An operator
      # comparison must use one of the COMPARISON_OPERATORS, so
      # status || 'x' = status fails. Each constant may be cast, but nothing
      # else may wrap it. The other side must be the column itself, or the
      # column under casts and COLLATE, as in
      # status::text COLLATE "C" = 'open'::text, not an expression on it
      # such as lower(status). Every cast's type modifiers, on either side,
      # must be integer constants (varchar(10)), so 'x'::mytype('secret')
      # fails. A constant anywhere else, such as in a function call ('bob'
      # in lower('bob')), compared with another constant, or standing alone
      # (true), fails. So does a cast's type modifier outside those
      # comparisons (flag::varchar(10)). A predicate with no constants
      # passes.
      def constants_compared_with_columns?(sql) = !stray_constant?(IndexSql.parse_predicate(sql))

      def stray_constant?(node)
        node = unwrap(node)
        return true if node.is_a?(PgQuery::A_Const)
        return false if column_comparison?(node)

        children(node).any? { |child| stray_constant?(child) }
      end

      # The operators AEXPR_OP, AEXPR_OP_ANY, and AEXPR_OP_ALL may use:
      # comparisons, and LIKE and ILIKE as a plan prints them (~~, !~~, ~~*,
      # !~~*). The parser reads != as <>. Any other operator, such as ||, +,
      # ->, or @>, computes a value rather than comparing one, so its
      # constant isn't compared with the column.
      COMPARISON_OPERATORS = %w[= <> < <= > >= ~~ !~~ ~~* !~~*].to_set.freeze

      OPERATOR_KINDS = %i[AEXPR_OP AEXPR_OP_ANY AEXPR_OP_ALL].to_set.freeze

      def column_comparison?(node)
        return false unless node.is_a?(PgQuery::A_Expr) && COMPARISONS.include?(node.kind)
        return false unless comparison_operator?(node)

        left = unwrap(node.lexpr)
        right = unwrap(node.rexpr)
        column_and_value?(left, right) || column_and_value?(right, left)
      end

      # An operator name may come with a schema, as in
      # OPERATOR(pg_catalog.=), and then only pg_catalog counts.
      def comparison_operator?(node)
        return true unless OPERATOR_KINDS.include?(node.kind)

        *schema, name = node.name.map { |n| unwrap(n).sval }
        COMPARISON_OPERATORS.include?(name) && [[], ["pg_catalog"]].include?(schema)
      end

      def column_and_value?(column, value) = column?(column) && (constant?(value) || constant_list?(value))

      # A column reference, bare or under casts and COLLATE, as a plan
      # prints a varchar column compared with text, (status)::text, or with
      # a collation, (status)::text COLLATE "C". A collation name is shape.
      # Any other expression on it, such as lower(status), isn't one.
      def column?(node)
        case node = unwrap(node)
        when PgQuery::ColumnRef then true
        when PgQuery::CollateClause then column?(node.arg)
        when PgQuery::TypeCast then plain_type?(node.type_name) && column?(node.arg)
        else false
        end
      end

      # A constant, a cast of one, or an ARRAY[...] of them.
      def constant?(node)
        case node = unwrap(node)
        when PgQuery::A_Const then true
        when PgQuery::TypeCast then plain_type?(node.type_name) && constant?(node.arg)
        when PgQuery::A_ArrayExpr then node.elements.all? { |e| constant?(e) }
        else false
        end
      end

      # A cast's type whose modifiers, if any, are all integer constants,
      # as in varchar(10) or numeric(10, 2). mytype('secret') isn't.
      def plain_type?(type_name) = type_name.typmods.all? { |m| unwrap(m).is_a?(PgQuery::A_Const) && unwrap(m).ival }

      # The list after IN, or BETWEEN's two bounds.
      def constant_list?(node) = node.is_a?(PgQuery::List) && node.items.all? { |item| constant?(item) }

      # Whether the predicate holds no literal and is only an AND of bare
      # columns tested as col IS NULL, col IS NOT NULL, col, or NOT col.
      # Such a predicate carries no values, only column names, so its
      # columns needn't be low-cardinality (20260923-36).
      def literal_free?(sql) = literal_free_node?(IndexSql.parse_predicate(sql))

      def literal_free_node?(node)
        case node = unwrap(node)
        when PgQuery::ColumnRef then node.fields.size == 1 && !unwrap(node.fields.first).is_a?(PgQuery::A_Star)
        when PgQuery::NullTest then literal_free_column?(node.arg)
        when PgQuery::BoolExpr then literal_free_bool?(node)
        else false
        end
      end

      def literal_free_bool?(node)
        case node.boolop
        when :AND_EXPR then node.args.all? { |arg| literal_free_node?(arg) }
        when :NOT_EXPR then literal_free_column?(node.args.first)
        else false
        end
      end

      def literal_free_column?(node) = unwrap(node).is_a?(PgQuery::ColumnRef) && literal_free_node?(node)

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
