# frozen_string_literal: true

require "pg_query"
require_relative "../value_pools"
require_relative "../constant_value"

module Quaack
  module Enclave
    module Fuzz
      # The queries whose per-atom coverage (Coverage) could follow a
      # literal, or a volatile function, so Coverage reports every atom
      # untested for them without checking any (task 20261012-4; the rule
      # of task 20261011-2, from the vacuity guard's search).
      #
      #   Reach.worst_case?("SELECT ... HAVING count(*) > 2")  # => true
      #
      # A volatile function's call can make a loosened query differ on its
      # own. And whether a random world reaches past a count threshold
      # follows the threshold: fuzz's copies stop at 101 rows a table, so
      # HAVING count(*) > 200 never comes out true, and which atoms were
      # seen both ways would carry the literal out.
      module Reach
        VOLATILE = %w[random setseed clock_timestamp timeofday nextval setval gen_random_uuid uuid_generate_v1
                      uuid_generate_v4 txid_current pg_sleep].freeze
        AGGREGATES = %w[count sum avg min max array_agg string_agg bool_and bool_or every].freeze

        module_function

        def worst_case?(sql, binding = nil) = volatile?(sql) || threshold_bound?(sql, binding)

        def volatile?(sql) = PgQuery.parse(sql).functions.intersect?(VOLATILE)

        # Whether the query compares an aggregate with a constant anywhere.
        #
        # It also counts a constant compared with a column when a derived
        # table or CTE holds an aggregate or window call, since that column
        # can carry the aggregate out a layer or more (t.k > 2 over a GROUP
        # BY's count(*) AS k). It doesn't trace which column is which, so it
        # fails closed: any such comparison counts.
        def threshold_bound?(sql, binding = nil)
          all = nodes(PgQuery.parse(sql).tree)
          all.any? { threshold?(it, binding) } ||
            (all.any? { fed_layer?(it) } && all.any? { column_compared?(it, binding) })
        end

        # A derived table's or CTE's SELECT whose select list holds an
        # aggregate or window call anywhere (failing closed: not only its
        # select list).
        def fed_layer?(node)
          select = (node.subquery if node.is_a?(PgQuery::RangeSubselect)) ||
                   (node.ctequery if node.is_a?(PgQuery::CommonTableExpr))
          select && nodes(select).any? { it.is_a?(PgQuery::FuncCall) && (aggregate_call?(it) || it.over) }
        end

        # A constant, or a list of them (IN, BETWEEN), compared with a
        # column, either side.
        def column_compared?(node, binding)
          return false unless node.is_a?(PgQuery::A_Expr) && node.lexpr && node.rexpr

          sides = [node.lexpr, node.rexpr]
          sides.any?(&:column_ref) && sides.any? { constant?(it, binding) || constants?(it, binding) }
        end

        def constants?(node, binding) = !!node.list && node.list.items.any? { constant?(it, binding) }

        def nodes(node, found = [])
          found << node
          ValuePools::Sides.children(node).each { nodes(it, found) }
          found
        end

        def threshold?(node, binding)
          return false unless node.is_a?(PgQuery::A_Expr) && node.lexpr && node.rexpr

          sides = [node.lexpr, node.rexpr]
          sides.any? { constant?(it, binding) } && sides.any? { aggregate?(it) }
        end

        # A constant: a literal, or a $n binding holds (ConstantValue), bare
        # or under a cast.
        def constant?(node, binding)
          !!(ConstantValue.from_node(node, binding) || ConstantValue.from_node(node.type_cast&.arg, binding))
        end

        def aggregate?(node)
          node = node.type_cast.arg if node.type_cast
          return aggregate_call?(node.func_call) if node.func_call

          targets(node).any? { aggregate?(it) }
        end

        # A scalar subquery's output expressions.
        def targets(node)
          select = node.sub_link&.subselect&.select_stmt
          select ? select.target_list.filter_map { it.res_target&.val } : []
        end

        def aggregate_call?(call) = call.agg_star || AGGREGATES.include?(call.funcname.last&.string&.sval)
      end
    end
  end
end
