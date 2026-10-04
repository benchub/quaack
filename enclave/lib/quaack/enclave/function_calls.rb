# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # Every function, operator, and cast a parse calls by name, for the
    # volatility check (DESIGN.md's volatility). It reads only the parse.
    #
    #   FunctionCalls.of(PgQuery.parse("SELECT random() WHERE 1 IN (2)").tree)
    #   # => [Call(kind: :function, schema: nil, name: "random", arity: 0),
    #   #     Call(kind: :operator, schema: nil, name: "=", arity: "b")]
    #
    # That's every call the query spells out, anywhere in it, and the
    # operators that syntax calls without spelling them out: IN, ANY and
    # ALL, BETWEEN, LIKE and its kin, IS DISTINCT FROM, NULLIF, a simple
    # CASE, JOIN USING and NATURAL JOIN, and ORDER BY USING. A call with
    # one argument may be a cast to the type of that name, as in int4(x),
    # so it's also listed as one. A qualified column, t.f, may be attribute
    # notation for f(t), so it's listed as an :attribute call. The parse should use only what
    # SupportedSql lists, which VolatilityCheck makes sure of.
    #
    # The SQL-value functions, such as CURRENT_TIMESTAMP, aren't listed,
    # since they're all stable or immutable. Neither is anything Postgres
    # adds on its own while it analyzes the query, such as an implicit cast
    # to fit a function's argument or the sort operator of a type's default
    # operator class. Those aren't in the parse.
    module FunctionCalls
      # One call. kind is :function, :operator, or :cast. schema is nil
      # when the query doesn't name one. arity is a function's argument
      # count, or an operator's kind as pg_operator.oprkind writes it, and
      # nil for a cast.
      Call = Data.define(:kind, :schema, :name, :arity)

      BINARY = "b"
      PREFIX = "l"

      # The operators BETWEEN and its kin call, which the parse names only
      # by the syntax.
      BETWEEN_OPERATORS = {
        AEXPR_BETWEEN: %w[>= <=], AEXPR_BETWEEN_SYM: %w[>= <=],
        AEXPR_NOT_BETWEEN: %w[< >], AEXPR_NOT_BETWEEN_SYM: %w[< >]
      }.freeze

      # The method that lists each kind of node's own calls, not counting
      # its children's.
      HANDLERS = {
        PgQuery::FuncCall => :function_call, PgQuery::A_Expr => :a_expr, PgQuery::TypeCast => :type_cast,
        PgQuery::SubLink => :sublink, PgQuery::CaseExpr => :simple_case, PgQuery::JoinExpr => :join,
        PgQuery::SortBy => :sort_by, PgQuery::ColumnRef => :column_ref
      }.freeze

      module_function

      def of(tree)
        found = []
        collect(tree, found)
        found
      end

      def collect(node, found)
        case node
        when Google::Protobuf::RepeatedField then node.each { |child| collect(child, found) }
        when Google::Protobuf::MessageExts
          handler = HANDLERS[node.class]
          found.concat(send(handler, node)) if handler
          node.class.descriptor.each { |field| collect(field.get(node), found) }
        end
      end

      # An ordered-set or hypothetical-set aggregate's WITHIN GROUP
      # arguments count toward its pronargs, like its direct ones.
      def function_call(func)
        count = func.args.size + (func.agg_within_group ? func.agg_order.size : 0)
        function = call_to(:function, func.funcname, count)
        count == 1 ? [function, call_to(:cast, func.funcname, nil)] : [function]
      end

      # t.f may be attribute notation, a call of the function f on t's row,
      # since the parse can't tell it from a column. Its kind is :attribute,
      # and it's looked up by name only, so it never has a schema.
      def column_ref(ref)
        last = ref.fields.last
        return [] unless ref.fields.size > 1 && last&.string

        [Call.new(kind: :attribute, schema: nil, name: last.string.sval, arity: nil)]
      end

      def a_expr(expr)
        if (ops = BETWEEN_OPERATORS[expr.kind])
          ops.map { |op| call_to(:operator, [op], BINARY) }
        else
          [call_to(:operator, expr.name, expr.lexpr ? BINARY : PREFIX)]
        end
      end

      def type_cast(cast) = [call_to(:cast, cast.type_name.names, nil)]

      # x IN (SELECT ...) has no operator name, and calls =.
      def sublink(link)
        case link.sub_link_type
        when :ANY_SUBLINK, :ALL_SUBLINK
          link.oper_name.any? ? [call_to(:operator, link.oper_name, BINARY)] : [equals]
        else []
        end
      end

      def simple_case(expr) = expr.arg ? [equals] : []

      def join(join) = join.is_natural || join.using_clause.any? ? [equals] : []

      def sort_by(sort) = sort.use_op.any? ? [call_to(:operator, sort.use_op, BINARY)] : []

      def equals = call_to(:operator, ["="], BINARY)

      # names is the parse's list of String nodes, or plain Strings, ending
      # in the name and led by its schema, if any, and even a database.
      def call_to(kind, names, arity)
        parts = names.map { |part| part.is_a?(String) ? part : part.string.sval }
        Call.new(kind:, schema: parts.length > 1 ? parts[-2] : nil, name: parts.last, arity:)
      end
    end
  end
end
