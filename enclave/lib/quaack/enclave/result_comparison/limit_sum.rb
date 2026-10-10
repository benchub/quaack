# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module ResultComparison
      # Shape#through_window's LIMIT: a SelectStmt's OFFSET added to its
      # LIMIT, as one expression, with no OFFSET. The sum stops at the
      # biggest bigint, so a LIMIT of that, or near it, doesn't overflow,
      # and a NULL OFFSET counts as 0. A NULL LIMIT is still no limit:
      #
      #   CASE WHEN l IS NULL THEN NULL
      #        ELSE LEAST(l, 9223372036854775807 - o) + o END
      #
      # with l and o each cast to bigint, and o coalesced to 0.
      module LimitSum
        BIGGEST = "9223372036854775807"

        module_function

        # Changes select in place. It raises ArgumentError, with a fixed
        # message, for one without both, since pg_query's deparser can
        # crash on a cast of nothing.
        def add_offset!(select)
          limit = select.limit_count
          offset = select.limit_offset
          raise ArgumentError, "through_offset! needs a LIMIT and an OFFSET" unless limit && offset

          select.limit_count = expression(bigint(limit), coalesce_zero(bigint(offset)))
          select.limit_offset = nil
        end

        def expression(limit, offset)
          clamped = operator("+", min_max(copy(limit), operator("-", biggest, copy(offset))), copy(offset))
          case_node(null_test(limit), a_const(isnull: true), clamped)
        end

        def copy(node) = node.class.decode(node.class.encode(node))

        def operator(name, left, right)
          symbol = PgQuery::Node.new(string: PgQuery::String.new(sval: name))
          PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind: :AEXPR_OP, name: [symbol], lexpr: left, rexpr: right))
        end

        def a_const(**value) = PgQuery::Node.new(a_const: PgQuery::A_Const.new(**value))
        def biggest = bigint(a_const(fval: PgQuery::Float.new(fval: BIGGEST)))
        def null_test(arg) = PgQuery::Node.new(null_test: PgQuery::NullTest.new(arg:, nulltesttype: :IS_NULL))
        def min_max(*args) = PgQuery::Node.new(min_max_expr: PgQuery::MinMaxExpr.new(op: :IS_LEAST, args:))

        def coalesce_zero(node)
          zero = bigint(a_const(ival: PgQuery::Integer.new(ival: 0)))
          PgQuery::Node.new(coalesce_expr: PgQuery::CoalesceExpr.new(args: [node, zero]))
        end

        def case_node(test, result, otherwise)
          arm = PgQuery::Node.new(case_when: PgQuery::CaseWhen.new(expr: test, result:))
          PgQuery::Node.new(case_expr: PgQuery::CaseExpr.new(args: [arm], defresult: otherwise))
        end

        def bigint(node)
          names = %w[pg_catalog int8].map { PgQuery::Node.new(string: PgQuery::String.new(sval: it)) }
          type_name = PgQuery::TypeName.new(names:, typemod: -1)
          PgQuery::Node.new(type_cast: PgQuery::TypeCast.new(arg: node, type_name:))
        end
      end
    end
  end
end
