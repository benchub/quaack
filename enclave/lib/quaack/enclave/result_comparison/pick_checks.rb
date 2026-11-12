# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module ResultComparison
      # The check that an arbitrary pick (Picks) has no real choice on the
      # data, built into the query in its place (task 20261008-67). Each
      # check divides by zero when the pick could keep values that print
      # differently, so the checked query fails on the data, at run time,
      # since its divisor reads the data. Texts compare under "C", so 'a'
      # and 'A' differ under any collation.
      #
      # - An aggregate: an array_agg of its arguments' texts, sorted after
      #   its own ORDER BY one way, is the one sorted the other way. That
      #   holds just when the rows in each run its ORDER BY ties print the
      #   same, so every order Postgres could feed it gives the same value.
      # - DISTINCT ON: the rows that tie first in its group, on its ORDER
      #   BY, all print the same.
      # - DISTINCT or a set operation, forced as Picks' PICK subquery: the
      #   rows Postgres calls equal all print the same.
      #
      # Each check reads its own group, so it holds for every group and
      # every run of a subquery, and a check over a pick downstream of
      # another reads the values the first one could only have kept.
      module PickChecks # rubocop:disable Metrics/ModuleLength -- one check per kind of pick
        # The SQLSTATE a check fails with, division_by_zero.
        FAILED = "22012"

        CHECKS = {
          aggregate: "CASE WHEN quaack_first = quaack_last THEN quaack_value " \
                     "WHEN 1 / (0 * length(quaack_first)) = 0 THEN quaack_value END",
          extreme: "CASE WHEN quaack_first IS NOT DISTINCT FROM quaack_last THEN quaack_value " \
                   "WHEN 1 / (0 * length(quaack_first)) = 0 THEN quaack_value END",
          group: "CASE WHEN quaack_min IS NOT DISTINCT FROM quaack_max THEN true " \
                 "ELSE 1 / (0 * length(quaack_min)) = 0 END",
          distinct_on: "CASE WHEN rank() OVER (PARTITION BY quaack_keys ORDER BY quaack_sorts) <> 1 THEN 0 " \
                       "WHEN min(quaack_row) OVER (PARTITION BY quaack_ties) = " \
                       "max(quaack_row) OVER (PARTITION BY quaack_ties) THEN 0 " \
                       "ELSE 1 / (0 * length(quaack_row)) END",
          dedup: "CASE WHEN min(quaack_row) OVER (PARTITION BY quaack_pick) = " \
                 "max(quaack_row) OVER (PARTITION BY quaack_pick) THEN 0 ELSE 1 / (0 * length(quaack_row)) END"
        }.freeze

        module_function

        # forced, the aggregate call forced, in a check of call.
        def aggregate(call, forced)
          texts = call[:args].map { c_text(copy(it)) }
          template(CHECKS[:aggregate], first: listed(call, texts, false), last: listed(call, texts, true),
                                       value: forced)
        end

        def listed(call, texts, descending)
          order = Array(copy(call[:agg_order])) + texts.map { Picks.sort(copy(it), descending) }
          c_text(func_call: copy(call).merge(funcname: [Picks.name("pg_catalog"), Picks.name("array_agg")],
                                             args: [template("ROW(quaack_texts)", texts:)], agg_order: order,
                                             agg_filter: listed_filter(call), func_variadic: false))
        end

        # any_value ignores NULL inputs, so its check leaves them out too
        # (task 20261015-6).
        def listed_filter(call)
          return copy(call[:agg_filter]) unless call[:funcname].last.dig(:string, :sval) == "any_value"

          # num_nonnulls tests the value, where IS NOT NULL on a row tests
          # its fields, and any_value keeps a row with a NULL field.
          null = "pg_catalog.num_nonnulls(quaack_arg) = 1"
          filter = call[:agg_filter] ? "#{null} AND (quaack_filter)" : null
          template(filter, arg: copy(call[:args].first), filter: copy(call[:agg_filter]))
        end

        # A min or max in a check that its argument's values tied for the
        # min or max all print the same: the first and the last of their
        # texts, sorted by the argument and then its text, are one text.
        def extreme(call)
          arg = call[:args].first
          direction = call[:funcname].last.dig(:string, :sval) == "max" ? "DESC" : ""
          bounds = %w[ASC DESC].to_h do |order|
            [order, tied_text(call, arg, "#{direction}, quaack_text #{order}")]
          end
          template(CHECKS[:extreme], first: bounds["ASC"], last: bounds["DESC"], value: { func_call: copy(call) })
        end

        def tied_text(call, arg, order)
          filter = call[:agg_filter] ? "quaack_arg IS NOT NULL AND (quaack_filter)" : "quaack_arg IS NOT NULL"
          template("(pg_catalog.array_agg(quaack_text ORDER BY quaack_arg #{order}) FILTER (WHERE #{filter}))[1]",
                   text: printed(copy(arg)), arg: copy(arg), filter: copy(call[:agg_filter]))
        end

        # The check, for a HAVING, that each of select's GROUP BY keys
        # prints one way in each group, or nil when it has none. (Grouping
        # sets are unsupported in v1, so SupportedSql refuses them first.)
        def grouped(select)
          checks = Array(select[:group_clause]).map do |key|
            text = printed(resolved(select, key))
            template(CHECKS[:group], min: aggregate_of("min", text), max: aggregate_of("max", copy(text)))
          end
          checks.reduce { |all, check| both(all, check) }
        end

        # left AND right, as one AND over their terms, as Postgres parses it.
        def both(left, right)
          node = template("quaack_left AND quaack_right", left:, right:)
          node[:bool_expr][:args] = node[:bool_expr][:args].flat_map do |term|
            term.dig(:bool_expr, :boolop) == :AND_EXPR ? term[:bool_expr][:args] : [term]
          end
          node
        end

        def aggregate_of(name, arg)
          template("pg_catalog.#{name}(quaack_arg)", arg:)
        end

        # The check of select's DISTINCT ON keys, sorted by sorts.
        def distinct_on(select, keys, sorts)
          keys = keys.map { resolved(select, it) }
          sorts = sorts.map { { sort_by: it[:sort_by].merge(node: resolved(select, it[:sort_by][:node])) } }
          template(CHECKS[:distinct_on], keys:, sorts:, ties: keys + sorts.map { it[:sort_by][:node] },
                                         row: output_row(select))
        end

        def output_row(select) = c_text(template("ROW(quaack_texts)", texts: Picks.output_keys(select)))

        # The check of a forced DISTINCT whose whole row is row.
        def dedup(row) = template(CHECKS[:dedup], row: c_text(copy(row)))

        # The expression an ORDER BY or DISTINCT ON item names: an output
        # column's, by its position or its name, or else its own. Raises
        # Picks::Unforceable for a position past the end or a *. A $n there
        # is a constant sort key, never a position: redact leaves positions
        # as they're written.
        def resolved(select, node)
          target = named_target(Array(select[:target_list]).map { it[:res_target] }, node)
          value = target ? target[:val] : node
          raise Picks::Unforceable if value.dig(:column_ref, :fields)&.last&.key?(:a_star)

          copy(value)
        end

        def named_target(targets, node)
          if (position = node.dig(:a_const, :ival))
            targets.fetch(position.fetch(:ival, 0) - 1) { raise Picks::Unforceable }
          elsif (field = bare_name(node))
            targets.find { (it[:name] || implicit_name(it[:val])) == field }
          end
        end

        def bare_name(node)
          fields = node.dig(:column_ref, :fields)
          fields.first.dig(:string, :sval) if fields&.size == 1
        end

        # The name Postgres gives an unnamed output column, where an ORDER
        # BY could use it.
        def implicit_name(value)
          if (fields = value.dig(:column_ref, :fields)) then fields.last.dig(:string, :sval)
          elsif (call = value[:func_call]) then call[:funcname].last.dig(:string, :sval)
          elsif (cast = value[:type_cast])
            implicit_name(cast[:arg]) || cast[:type_name][:names].last.dig(:string, :sval)
          end
        end

        # expression's tree, with each quaack_ name in nodes replaced by a
        # copy of its node, or by copies of its list's nodes in a list.
        def template(expression, **nodes)
          tree = PgQuery.parse("SELECT #{expression}").tree.to_h
          substituted(tree[:stmts].first[:stmt][:select_stmt][:target_list].first[:res_target][:val], nodes)
        end

        def substituted(node, nodes)
          case node
          when Hash
            key = placeholder(node)
            nodes.key?(key) ? copy(nodes[key]) : node.transform_values { substituted(it, nodes) }
          when Array then node.flat_map { spliced(it, nodes) }
          else node
          end
        end

        def spliced(item, nodes)
          list = nodes[placeholder(item.is_a?(Hash) && item[:sort_by] ? item[:sort_by][:node] : item)]
          list.is_a?(Array) ? copy(list) : [substituted(item, nodes)]
        end

        def placeholder(node)
          name = node.is_a?(Hash) && bare_name(node)
          name.delete_prefix("quaack_").to_sym if name&.start_with?("quaack_")
        end

        # node's text, as c_text, but with a float4 or float8 -0 printed as
        # 0, which it equals, so a min, max, or GROUP BY key that could keep
        # either has no choice worth refusing: float noise (task
        # 20261110-8). Other types keep their text, such as numeric's 10.0.
        def printed(node)
          c_text_of(template("CASE WHEN pg_catalog.pg_typeof(quaack_arg) IN " \
                             "('pg_catalog.float4'::pg_catalog.regtype, 'pg_catalog.float8'::pg_catalog.regtype) " \
                             "AND quaack_text = '-0' THEN '0' ELSE quaack_text END",
                             arg: node, text: Picks.text(copy(node))))
        end

        def c_text_of(text) = { collate_clause: { arg: text, collname: [Picks.name("C")] } }
        def c_text(node) = c_text_of(Picks.text(node))
        def copy(node) = Marshal.load(Marshal.dump(node))
      end
    end
  end
end
