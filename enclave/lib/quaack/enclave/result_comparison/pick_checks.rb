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
      module PickChecks
        CHECKS = {
          aggregate: "CASE WHEN quaack_first = quaack_last THEN quaack_value " \
                     "WHEN 1 / (0 * length(quaack_first)) = 0 THEN quaack_value END",
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
                                             func_variadic: false))
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
        # Picks::Unforceable for a position past the end or a *.
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

        def c_text(node) = { collate_clause: { arg: Picks.text(node), collname: [Picks.name("C")] } }
        def copy(node) = Marshal.load(Marshal.dump(node))
      end
    end
  end
end
