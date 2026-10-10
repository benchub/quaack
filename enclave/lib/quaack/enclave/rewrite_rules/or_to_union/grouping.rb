# frozen_string_literal: true

require "pg_query"
require_relative "../tree"
require_relative "reads"

module Quaack
  module Enclave
    module RewriteRules
      class OrToUnion
        # Whether a query's GROUP BY and HAVING can read the UNION instead
        # of the join. The UNION holds each row of the join that passes the
        # WHERE exactly once, so grouping it gives the groups the join
        # would. What can differ is whether Postgres accepts the query. It
        # takes a.id, a.title ... GROUP BY a.id because a.id is a's primary
        # key, but the UNION's columns have no key, so the same query over
        # it raises. So a query with a GROUP BY or HAVING is taken only when:
        #
        # - Each GROUP BY item is a column written name.column: no
        #   expression, ordinal, ROLLUP, CUBE, GROUPING SETS, or ().
        # - Every column in the select list, HAVING, and ORDER BY that isn't
        #   inside an aggregate's call is one of those GROUP BY columns
        #   itself, so Postgres needs no key to accept it. That leaves out
        #   name.* and *, which aren't written name.column. A call is an
        #   aggregate only when every function of its name in the catalog
        #   is one; anything else is read as a plain call, whose columns
        #   must be grouped.
        module Grouping
          module_function

          def valid?(select, catalog)
            return true if select.group_clause.empty? && select.having_clause.nil?

            grouped = select.group_clause.map { Tree.qualified(it.column_ref) if it.node == :column_ref }
            grouped.all? && !select.group_distinct && grouped?(grouped, select, catalog)
          end

          def grouped?(grouped, select, catalog)
            loose(outside(select), catalog).all? { grouped.include?(Tree.qualified(it)) }
          end

          def outside(select) = [*select.target_list, select.having_clause, *select.sort_clause].compact

          # Every column in node that isn't inside an aggregate's call.
          def loose(node, catalog, found = [])
            case node
            when PgQuery::FuncCall then loose_call(node, catalog, found)
            when PgQuery::ColumnRef then found << node
            when Array, Google::Protobuf::RepeatedField then node.each { loose(it, catalog, found) }
            when PgQuery::Node then loose(node.inner, catalog, found)
            when Google::Protobuf::MessageExts then node.class.descriptor.each { loose(it.get(node), catalog, found) }
            end
            found
          end

          def loose_call(call, catalog, found)
            names = call.funcname.map { it.string.sval }
            return if catalog.only_aggregates?(names.length > 1 ? names[-2] : nil, names.last)

            call.class.descriptor.each { loose(it.get(call), catalog, found) }
          end
        end
      end
    end
  end
end
