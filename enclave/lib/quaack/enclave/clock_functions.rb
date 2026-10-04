# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # Which calls clock anchoring (clock-anchor) replaces, and with what. See
    # ClockAnchoring for the rules.
    #
    #   ClockFunctions.anchored_sql(node)  # => "quaack.clock_anchor()::pg_catalog.date", or nil
    module ClockFunctions
      ANCHOR = "quaack.clock_anchor()"
      FUNCTIONS = %w[now transaction_timestamp statement_timestamp].freeze

      # Each SQL-value function replaced, and the cast that keeps its type,
      # if it needs one.
      SQL_VALUE_CASTS = {
        SVFOP_CURRENT_TIMESTAMP: nil, SVFOP_CURRENT_TIMESTAMP_N: "pg_catalog.timestamptz",
        SVFOP_CURRENT_DATE: "pg_catalog.date",
        SVFOP_LOCALTIMESTAMP: "pg_catalog.timestamp", SVFOP_LOCALTIMESTAMP_N: "pg_catalog.timestamp",
        SVFOP_LOCALTIME: "pg_catalog.time", SVFOP_LOCALTIME_N: "pg_catalog.time"
      }.freeze

      PRECISION_OPS = %i[SVFOP_CURRENT_TIMESTAMP_N SVFOP_LOCALTIMESTAMP_N SVFOP_LOCALTIME_N].freeze

      module_function

      # The anchored expression's SQL for a node anchor replaces, or nil.
      def anchored_sql(node)
        case node.node
        when :func_call then ANCHOR if clock_function?(node.func_call)
        when :sqlvalue_function then sql_value_anchor(node.sqlvalue_function)
        end
      end

      def sql_value_anchor(svf)
        return unless SQL_VALUE_CASTS.key?(svf.op)

        cast = SQL_VALUE_CASTS[svf.op]
        return ANCHOR unless cast

        precision = PRECISION_OPS.include?(svf.op) ? "(#{Integer(svf.typmod)})" : ""
        "#{ANCHOR}::#{cast}#{precision}"
      end

      def clock_function?(func)
        names = name_parts(func)
        plain_call?(func) && FUNCTIONS.include?(names.last) && [1, 2].include?(names.length) &&
          (names.length == 1 || names.first == "pg_catalog")
      end

      # No arguments, so no DISTINCT or VARIADIC either, which need one. A
      # call with no arguments has an ORDER BY only from WITHIN GROUP.
      def plain_call?(func)
        func.args.empty? && func.agg_order.empty? && func.agg_filter.nil? && func.over.nil? && !func.agg_star
      end

      def name_parts(func) = func.funcname.map { |part| part.string.sval }
    end
  end
end
