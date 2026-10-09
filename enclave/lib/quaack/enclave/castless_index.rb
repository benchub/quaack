# frozen_string_literal: true

require "pg_query"
require_relative "deparse"
require_relative "index_candidate"
require_relative "index_sql"
require_relative "node_rewrite"

module Quaack
  module Enclave
    # An index candidate as the report tells two apart (DESIGN.md's negative-result): the
    # same candidate, with every cast on a constant, a bare column, or an
    # ARRAY[...] taken out of its predicate, each number constant written as
    # a string (amount > 10 and amount > '10'::numeric), and each
    # x = ANY (ARRAY[...]) written as x IN (...), as a plan prints an IN list.
    #
    #   CastlessIndex.key(a) == CastlessIndex.key(b)
    #
    # IndexCandidate keeps casts, since only the catalog can say what one
    # changes. So a partial index read from a plan, which prints
    # (status)::text = 'deleted'::text, and the same index from the query's
    # own text, status = 'deleted', are two candidates, and index-search tests both.
    # A reader of the report sees one index, so its lists send it once.
    # Sources don't count, as in IndexCandidate#==.
    #
    # This only groups lines of the report. Nothing is tested, built, or
    # dropped by it. A predicate the deparser can't write back faithfully
    # keeps its casts.
    #
    # Trust boundary. The key holds the predicate, so it's value-class
    # data, like the candidate. It's for comparing, never for sending.
    module CastlessIndex
      CASTLESS = %i[a_const column_ref a_array_expr].freeze

      module_function

      def key(candidate) = IndexCandidate.new(**candidate.to_h, predicate: predicate(candidate.predicate))

      def predicate(sql)
        return if sql.nil?

        holder = PgQuery::SelectStmt.new(where_clause: IndexSql.parse_predicate(sql))
        NodeRewrite.each(holder) { uncast(it) }
        NodeRewrite.each(holder) { spelled(it) } # rubocop:disable Style/CombinableLoops -- every cast must be gone first
        Deparse.expression(holder.where_clause)
      rescue Deparse::Error
        sql
      end

      # node in the one spelling the key uses, or nil to keep it as it is.
      # Its children are respelled first.
      def spelled(node)
        case node.node
        when :a_const then stringified(node.a_const)
        when :a_expr then in_list(node.a_expr)
        end
      end

      def stringified(const)
        text = case const.val
               when :ival then const.ival.ival.to_s
               when :fval then const.fval.fval
               end
        text && PgQuery::Node.new(a_const: PgQuery::A_Const.new(sval: PgQuery::String.new(sval: text)))
      end

      # An array literal's text ('{1,2}') whose elements are all plain and
      # unquoted. Anything else (quotes, NULL, nesting, empty) isn't merged.
      LITERAL = /\A\{[^{}"\\,\s]+(?:,[^{}"\\,\s]+)*\}\z/

      # x = ANY (ARRAY[...]) or x = ANY ('{...}') as x IN (...), its elements respelled too.
      def in_list(expr)
        return unless any_array?(expr)

        items = elements(expr.rexpr)&.map { spelled(it) || it }
        return unless items

        lexpr = spelled(expr.lexpr) || expr.lexpr
        PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind: :AEXPR_IN, name: expr.name.to_a, lexpr:,
                                                      rexpr: PgQuery::Node.new(list: PgQuery::List.new(items:))))
      end

      def any_array?(expr)
        expr.kind == :AEXPR_OP_ANY && expr.name.map { it.string.sval } == ["="]
      end

      def elements(rexpr)
        case rexpr&.node
        when :a_array_expr then rexpr.a_array_expr.elements.to_a
        when :a_const then literal_elements(rexpr.a_const)
        end
      end

      def literal_elements(const)
        text = const.val == :sval && const.sval.sval
        return unless text && LITERAL.match?(text)

        values = text[1...-1].split(",")
        return if values.any? { it.casecmp?("null") }

        values.map { PgQuery::Node.new(a_const: PgQuery::A_Const.new(sval: PgQuery::String.new(sval: it))) }
      end

      # The constant, column, or array under node's casts, its own
      # children uncast too, or nil if node isn't a cast of one.
      def uncast(node)
        inner = node
        inner = inner.type_cast.arg while inner.node == :type_cast
        return unless !inner.equal?(node) && CASTLESS.include?(inner.node)

        NodeRewrite.each(inner) { uncast(it) }
        inner
      end
    end
  end
end
