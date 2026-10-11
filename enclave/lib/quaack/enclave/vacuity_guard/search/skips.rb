# frozen_string_literal: true

require "pg_query"
require_relative "../../value_pools"

module Quaack
  module Enclave
    module VacuityGuard
      class Search
        # The queries the search leaves alone (Search#run).
        #
        #   Skips.skip?("SELECT ... LIMIT 1")  # => true
        #
        # One that calls a volatile function, since a difference could come
        # from the function. And one whose verdict could follow a literal
        # (20261010-47): a LIMIT or OFFSET anywhere, or an aggregate compared
        # with a constant (a count threshold past the rows a trial holds).
        module Skips
          VOLATILE = %w[random setseed clock_timestamp timeofday nextval setval gen_random_uuid uuid_generate_v1
                        uuid_generate_v4 txid_current pg_sleep].freeze
          AGGREGATES = %w[count sum avg min max array_agg string_agg bool_and bool_or every].freeze

          module_function

          def skip?(sql) = volatile?(sql) || literal_bound?(sql)

          def volatile?(sql) = PgQuery.parse(sql).functions.intersect?(VOLATILE)

          def literal_bound?(sql) = nodes(PgQuery.parse(sql).tree).any? { cut?(it) || threshold?(it) }

          def nodes(node, found = [])
            found << node
            ValuePools::Sides.children(node).each { nodes(it, found) }
            found
          end

          def cut?(node) = node.is_a?(PgQuery::SelectStmt) && !!(node.limit_count || node.limit_offset)

          def threshold?(node)
            return false unless node.is_a?(PgQuery::A_Expr) && node.lexpr && node.rexpr

            sides = [node.lexpr, node.rexpr]
            sides.any? { constant?(it) } && sides.any? { aggregate?(it) }
          end

          def constant?(node) = !!(node.a_const || node.type_cast&.arg&.a_const)

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
end
