# frozen_string_literal: true

require "pg_query"
require_relative "../../deparse"
require_relative "types"

module Quaack
  module Enclave
    module RewriteRules
      class SubqueryOrderRemoval
        # Whether a SELECT that reads a subquery's rows is blind to their
        # order: what it returns, and in what order, doesn't follow the
        # order the rows reach it in, beyond what its own ORDER BY leaves
        # open, which SQL leaves open too.
        #
        # Blind.reader? holds when the SELECT has no window function, no
        # WINDOW, and no DISTINCT ON, every call in its select list,
        # HAVING, and ORDER BY is an aggregate of AGGREGATES or a function
        # that gives one value per row, and either:
        #
        # - it has an ORDER BY of its own, which then decides the order of
        #   its rows, and which rows a LIMIT or OFFSET keeps, or
        # - it aggregates, by a GROUP BY or by an aggregate that isn't
        #   under a subquery, and has no LIMIT or OFFSET.
        #
        # A SELECT with neither returns its rows in the order they come,
        # which an app may rely on though SQL doesn't promise it.
        #
        # AGGREGATES are pg_catalog's own, called by a bare name or as
        # pg_catalog.name, when no other schema has a function of the name
        # (Catalog#builtin_aggregate?), and any aggregate with an ORDER BY
        # of its own, WITHIN GROUP included, which sorts its input itself.
        # count, bool_and, bool_or, and every never follow their input
        # order. min and max keep the first of two values that compare
        # equal, and a sum or avg of a float rounds in its input's order,
        # so Types checks what they read, and what a GROUP BY or DISTINCT
        # keeps.
        #
        # Every call under a subquery of the reader counts too, since an
        # aggregate there of only the reader's columns is the reader's.
        module Blind
          AGGREGATES = { "count" => :always, "bool_and" => :always, "bool_or" => :always, "every" => :always,
                         "min" => :same, "max" => :same, "sum" => :exact, "avg" => :exact }.freeze

          # A call in the reader, its kind (see kind), and whether it's
          # under a subquery.
          Call = Data.define(:call, :kind, :nested)

          module_function

          def reader?(select, tree, catalog, literals)
            return false unless select.window_clause.empty? && select.distinct_clause.all? { it.node.nil? }

            calls = calls_in(select, catalog)
            calls.all? { fits?(it, catalog) } && ordered_or_aggregated?(select, calls) &&
              Types.fit?(select, calls, tree, catalog, literals)
          end

          # A Call for each call in select's select list, HAVING, and ORDER
          # BY.
          def calls_in(select, catalog)
            [select.target_list, select.having_clause, select.sort_clause].flat_map { calls(it, false, []) }
                                                                          .map do |call, nested|
              Call.new(call:, kind: kind(call, catalog), nested:)
            end
          end

          # Whether select has an ORDER BY, or aggregates and has no LIMIT
          # or OFFSET.
          def ordered_or_aggregated?(select, calls)
            return true if select.sort_clause.any?

            aggregates = select.group_clause.any? || calls.any? { it.kind && !it.nested }
            aggregates && select.limit_count.nil? && select.limit_offset.nil?
          end

          # Every FuncCall in node, each with whether it's under a subquery.
          def calls(node, nested, found)
            case node
            when PgQuery::FuncCall then children(node, nested, found << [node, nested])
            when PgQuery::SubLink then calls(node.subselect, true, calls(node.testexpr, nested, found))
            when PgQuery::Node then calls(node.inner, nested, found)
            when Google::Protobuf::RepeatedField then node.each { calls(it, nested, found) }
            when Google::Protobuf::MessageExts then children(node, nested, found)
            end
            found
          end

          def children(node, nested, found) = node.class.descriptor.each { calls(it.get(node), nested, found) }

          # :window for a window call, :ordered for an aggregate with an
          # ORDER BY of its own, an AGGREGATES kind for one of
          # pg_catalog's, or nil for any other call.
          def kind(call, catalog)
            return :window if call.over
            return :ordered if call.agg_order.any?

            schema, name = names(call)
            kind = AGGREGATES[name] if name
            kind if kind && catalog.builtin_aggregate?(schema, name)
          end

          # [schema, name] for a call written name or pg_catalog.name, or
          # nil.
          def names(call)
            case call.funcname.map { it.string.sval }
            in [name] then [nil, name]
            in ["pg_catalog", name] then ["pg_catalog", name]
            else nil
            end
          end

          def fits?(call, catalog)
            case call.kind
            when :window then false
            when nil then plain?(call.call, catalog)
            when :same, :exact then !call.nested && call.call.args.size == 1
            else true
            end
          end

          # Whether no function of the call's name is an aggregate, a window
          # function, or returns a set. Its arguments' calls are found on
          # their own.
          def plain?(call, catalog)
            bare = PgQuery::FuncCall.new(funcname: call.funcname.map { Deparse.copy(it) })
            catalog.row_wise?([PgQuery::Node.new(func_call: bare)])
          end
        end
      end
    end
  end
end
