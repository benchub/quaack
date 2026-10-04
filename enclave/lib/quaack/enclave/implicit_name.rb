# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # The name Postgres gives an output column that has no AS, from the
    # parse, the way parse_target.c's FigureColnameInternal works it out.
    #
    #   ImplicitName.of(res_target.val)  # => "now", or "?column?"
    #
    # Each rule gives a name and a strength. A function call, column, or
    # keyword gives a strong name. A cast gives its type's name, but only
    # when what it casts has no strong name of its own, and CASE gives
    # "case" only when its ELSE has none. COLLATE takes its argument's
    # name, and a scalar subquery takes its first column's
    # ("column1" for VALUES). Anything else
    # has no name, and the column is "?column?".
    #
    # A subquery whose first column is * or t.* is named from the parse,
    # so it can differ from Postgres, which reads the analyzed columns.
    # Anchoring stays sound, because inner slots keep their own names.
    #
    # It covers what SupportedSql lists. Clock anchoring (clock-anchor) uses it only
    # to see whether anchoring changed a name, and Postgres itself checks
    # it in clock_anchoring_postgres_spec.rb.
    module ImplicitName
      NONE = [nil, 0].freeze
      UNNAMED = "?column?"

      SQL_VALUE_NAMES = {
        SVFOP_CURRENT_DATE: "current_date", SVFOP_CURRENT_TIME: "current_time",
        SVFOP_CURRENT_TIME_N: "current_time", SVFOP_CURRENT_TIMESTAMP: "current_timestamp",
        SVFOP_CURRENT_TIMESTAMP_N: "current_timestamp", SVFOP_LOCALTIME: "localtime",
        SVFOP_LOCALTIME_N: "localtime", SVFOP_LOCALTIMESTAMP: "localtimestamp",
        SVFOP_LOCALTIMESTAMP_N: "localtimestamp", SVFOP_CURRENT_ROLE: "current_role",
        SVFOP_CURRENT_USER: "current_user", SVFOP_USER: "user", SVFOP_SESSION_USER: "session_user",
        SVFOP_CURRENT_CATALOG: "current_catalog", SVFOP_CURRENT_SCHEMA: "current_schema"
      }.freeze

      SUBLINK_NAMES = { EXISTS_SUBLINK: "exists", ARRAY_SUBLINK: "array" }.freeze

      module_function

      def of(node) = figure(node).first || UNNAMED

      # [name, strength] for a PgQuery::Node, or NONE.
      def figure(node)
        return NONE unless node

        inner = node.inner
        method = :"figure_#{node.node}"
        respond_to?(method, true) ? send(method, inner) : NONE
      end

      def strong(name) = [name, 2]

      # The last field name, skipping a *.
      def figure_column_ref(ref)
        name = last_string(ref.fields)
        name ? strong(name) : NONE
      end

      # The last field name, skipping * and subscripts, or else the name
      # of what it selects from.
      def figure_a_indirection(ind)
        name = last_string(ind.indirection)
        name ? strong(name) : figure(ind.arg)
      end

      def last_string(nodes) = nodes.reverse_each.find(&:string)&.string&.sval

      def figure_func_call(func) = strong(func.funcname.last.string.sval)

      def figure_a_expr(expr) = expr.kind == :AEXPR_NULLIF ? strong("nullif") : NONE

      def figure_type_cast(cast)
        name, strength = figure(cast.arg)
        return [name, strength] if strength > 1

        [cast.type_name.names.last.string.sval, 1]
      end

      def figure_collate_clause(clause) = figure(clause.arg)

      def figure_case_expr(expr)
        name, strength = figure(expr.defresult)
        strength > 1 ? [name, strength] : ["case", 1]
      end

      def figure_sub_link(link)
        return strong(SUBLINK_NAMES[link.sub_link_type]) if SUBLINK_NAMES.key?(link.sub_link_type)
        return NONE unless link.sub_link_type == :EXPR_SUBLINK

        first_column(link.subselect.select_stmt)
      end

      # A set operation's columns are named by its leftmost SELECT, and
      # VALUES names them column1 and on.
      def first_column(select)
        select = select.larg until select.op == :SETOP_NONE
        return strong("column1") unless select.values_lists.empty?

        target = select.target_list.first&.res_target
        return NONE unless target

        strong(target.name.empty? ? of(target.val) : target.name)
      end

      def figure_a_array_expr(_) = strong("array")

      def figure_row_expr(_) = strong("row")

      def figure_coalesce_expr(_) = strong("coalesce")

      def figure_min_max_expr(expr) = strong(expr.op == :IS_GREATEST ? "greatest" : "least")

      def figure_sqlvalue_function(svf) = SQL_VALUE_NAMES.key?(svf.op) ? strong(SQL_VALUE_NAMES[svf.op]) : NONE

      def figure_grouping_func(_) = strong("grouping")
    end
  end
end
