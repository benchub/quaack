# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # Each function, operator, type, and collation a parse tree names
    # without a schema, as [kind, name] pairs, in tree order, for UserSchema.
    # Operators count where the query writes them, and where Postgres
    # supplies them unqualified: = for IN, NULLIF, IS DISTINCT FROM, a simple
    # CASE, and JOIN USING or NATURAL; >= and <= for BETWEEN, and < and > for
    # NOT BETWEEN.
    #
    #   UnqualifiedNames.of(PgQuery.parse("SELECT lower(a) FROM t WHERE b IN (1)").tree)
    #   # => [["function", "lower"], ["operator", "="]]
    module UnqualifiedNames
      # The operators Postgres compares with in place of an A_Expr's name,
      # for the kinds whose name isn't an operator's.
      BETWEEN_OPERATORS = {
        AEXPR_BETWEEN: %w[>= <=], AEXPR_BETWEEN_SYM: %w[>= <=],
        AEXPR_NOT_BETWEEN: %w[< >], AEXPR_NOT_BETWEEN_SYM: %w[< >]
      }.freeze

      module_function

      def of(node, found = [])
        found.concat(own_names(node))
        children(node).each { of(it, found) }
        found
      end

      def own_names(node)
        case node
        when PgQuery::FuncCall then unqualified("function", [node.funcname])
        when PgQuery::TypeName then unqualified("type", [node.names])
        when PgQuery::CollateClause then unqualified("collation", [node.collname])
        else unqualified("operator", operators(node))
        end
      end

      # The name lists of the operators node compares with, written or not.
      def operators(node)
        written = case node
                  when PgQuery::A_Expr then BETWEEN_OPERATORS[node.kind]&.map { name_list(it) } || [node.name]
                  when PgQuery::SubLink then [node.oper_name]
                  when PgQuery::SortBy then [node.use_op]
                  else []
                  end
        implicit_equals?(node) ? [*written, name_list("=")] : written
      end

      # Whether node compares with an = the query doesn't write: IN
      # (subquery), a simple CASE, or JOIN USING or NATURAL.
      def implicit_equals?(node)
        case node
        when PgQuery::SubLink then node.oper_name.empty? && node.sub_link_type == :ANY_SUBLINK
        when PgQuery::CaseExpr then !node.arg.nil?
        when PgQuery::JoinExpr then node.is_natural || node.using_clause.any?
        else false
        end
      end

      def name_list(name) = [PgQuery::Node.new(string: PgQuery::String.new(sval: name))]

      # A [kind, name] pair for each name list that has no schema.
      def unqualified(kind, lists) = lists.select { it.size == 1 }.map { [kind, it.last.string.sval] }

      def children(node)
        case node
        when Google::Protobuf::RepeatedField then node.to_a
        when PgQuery::Node then [node.inner]
        when Google::Protobuf::MessageExts then node.class.descriptor.map { it.get(node) }
        else []
        end
      end
    end
  end
end
