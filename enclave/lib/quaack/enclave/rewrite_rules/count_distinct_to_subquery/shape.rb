# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class CountDistinctToSubquery
        # Whether a SELECT has the shape the rule takes, and how its parts
        # read: its grouping columns, its one count(DISTINCT e), its
        # outputs' names, and what each ORDER BY item becomes.
        module Shape
          COUNT = [%w[count], %w[pg_catalog count]].freeze

          module_function

          def fits?(select)
            plain?(select) && unlimited?(select) && (call = count(select)) && value?(call.args.first) &&
              grouped_by_columns?(select) && unique_names?(select) &&
              select.sort_clause.all? { sort_key(it.sort_by.node, select) }
          end

          # Whether select is one SELECT with a FROM, and no HAVING, WINDOW,
          # or DISTINCT.
          def plain?(select)
            select.op == :SETOP_NONE && select.from_clause.any? && select.having_clause.nil? &&
              select.window_clause.empty? && select.distinct_clause.empty?
          end

          # Whether select has no locking clause, GROUP BY DISTINCT, or FETCH
          # WITH TIES.
          def unlimited?(select)
            select.locking_clause.empty? && !select.group_distinct &&
              select.limit_option != :LIMIT_OPTION_WITH_TIES
          end

          # The select list's one count(DISTINCT e), when every other item is
          # a name.column.
          def count(select)
            vals = select.target_list.map { it.res_target.val }
            counts = vals.select { counted?(it) }
            counts.first.func_call if counts.one? && (vals - counts).all? { column(it) }
          end

          def counted?(node)
            call = node.func_call if node.node == :func_call
            call && COUNT.include?(call.funcname.map { it.string.sval }) && call.agg_distinct && call.args.one? &&
              bare_call?(call)
          end

          # Whether call has no FILTER, ORDER BY, OVER, *, WITHIN GROUP, or
          # VARIADIC.
          def bare_call?(call)
            call.agg_filter.nil? && call.agg_order.empty? && call.over.nil? &&
              [call.agg_star, call.agg_within_group, call.func_variadic].none?
          end

          # Whether e is more than a constant or placeholder.
          def value?(node)
            node = node.type_cast.arg while node.node == :type_cast
            !%i[a_const param_ref].include?(node.node)
          end

          # [qualifier, column] of a name.column, [nil, column] of a bare
          # column, or nil. A bare name in the subquery reads the same FROM,
          # so it means what it did.
          def column(node)
            return unless node.node == :column_ref

            ref = node.column_ref
            Tree.qualified(ref) || ([nil, Tree.bare_name(ref)] if Tree.bare_name(ref))
          end

          # The column a GROUP BY item names: a column as column reads it,
          # or an ordinal's select-list item's, or nil.
          def group_column(node, select)
            return column(node) unless node.node == :a_const && node.a_const.val == :ival

            index = node.a_const.ival.ival
            target = select.target_list[index - 1] if index.positive?
            column(target.res_target.val) if target
          end

          def columns(select) = select.target_list.filter_map { column(it.res_target.val) }

          def grouped_by_columns?(select)
            groups = select.group_clause.map { group_column(it, select) }
            groups.all? && groups.to_set == columns(select).to_set
          end

          # Whether no two grouping columns share a column name, and no two
          # outputs share a name.
          def unique_names?(select)
            names = columns(select).map(&:last)
            outputs = output_names(select)
            names.uniq.size == names.size && outputs.uniq.size == outputs.size
          end

          def output_names(select)
            select.target_list.map do |target|
              target = target.res_target
              next target.name unless target.name.empty?

              column(target.val)&.last || "count"
            end
          end

          # What an ORDER BY item becomes: a grouping column's name, :keep
          # for an output's name or an ordinal, or nil for anything else.
          def sort_key(node, select)
            return :keep if node.node == :a_const && node.a_const.val == :ival
            return :keep if node.node == :column_ref && output_names(select).include?(Tree.bare_name(node.column_ref))

            found = column(node)
            found&.last if columns(select).include?(found)
          end
        end
      end
    end
  end
end
