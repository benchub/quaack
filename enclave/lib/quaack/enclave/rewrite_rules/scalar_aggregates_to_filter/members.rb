# frozen_string_literal: true

require "pg_query"
require_relative "../../deparse"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class ScalarAggregatesToFilter
        # Finds a SELECT's members, and says which conditions can't raise.
        module Members
          # Each member's table name becomes this when its conjuncts are
          # compared.
          COPY = "quaack_copy"
          COMPARISONS = %w[= <> < > <= >=].freeze
          # Built-in aggregates that can't raise over * or a bare column.
          AGGREGATES = %w[count sum avg min max bool_and bool_or every].freeze

          # A member: its outer ResTarget, its SELECT, table, and aggregate
          # call, and its conjuncts with the table's name as COPY.
          Member = Data.define(:target, :select, :range, :call, :conditions)

          def members(top, catalog)
            top.target_list.filter_map do |item|
              select = subquery(item.res_target.val)
              member(item.res_target, select, catalog, top.from_clause.any?) if select
            end
          end

          def subquery(node)
            link = node.sub_link if node.node == :sub_link
            link.subselect.select_stmt if link&.sub_link_type == :EXPR_SUBLINK
          end

          # Whether node can't raise: a comparison, IN list, or IS NULL of
          # columns, constants, and placeholders, or an AND, OR, or NOT of
          # those.
          def harmless?(node)
            case node.node
            when :a_expr then harmless_expr?(node.a_expr)
            when :null_test then atom?(node.null_test.arg)
            when :bool_expr then node.bool_expr.args.all? { harmless?(it) }
            else false
            end
          end

          def requalified(node, from, to)
            Deparse.copy(node).tap do |copy|
              Tree.find(copy, PgQuery::ColumnRef).each { Tree.qualify!(it, to) if Tree.qualified(it)&.first == from }
            end
          end

          def function_name(call)
            names = call.funcname.map { it.string.sval }
            names.size == 2 ? names : [nil, names.last]
          end

          private

          # With a FROM, which can give no rows, every condition of the
          # member and its aggregate must be harmless.
          def member(target, select, catalog, from)
            return unless shape?(select) && aggregate?(call_of(select), catalog)

            range = select.from_clause.first.range_var
            conditions = Tree.conjuncts(select.where_clause).map { requalified(it, Tree.refname(range), COPY) }
            return if from && raises?(conditions, select)

            Member.new(target:, select:, range:, call: call_of(select), conditions:)
          end

          def raises?(conditions, select) = !(conditions.all? { harmless?(it) } && harmless_call?(call_of(select)))

          def call_of(select) = select.target_list.first.res_target.val.func_call

          def shape?(select)
            select.op == :SETOP_NONE && Tree.plain_select?(select) && select.distinct_clause.empty? &&
              one_table?(select.from_clause) && one_call?(select.target_list) &&
              Tree.find(select, PgQuery::SubLink).empty?
          end

          def one_table?(from)
            from.size == 1 && from.first.node == :range_var && Tree.plain_table?(from.first.range_var, only: true)
          end

          def one_call?(targets) = targets.size == 1 && targets.first.res_target.val.node == :func_call

          def aggregate?(call, catalog)
            return false if call.agg_filter || call.over || call.agg_within_group

            catalog.only_aggregates?(*function_name(call)) && catalog.row_wise?(call.args.to_a + call.agg_order.to_a)
          end

          def harmless_call?(call)
            schema, name = function_name(call)
            [nil, "pg_catalog"].include?(schema) && AGGREGATES.include?(name) && call.agg_order.empty? &&
              (call.agg_star || (call.args.size == 1 && call.args.first.node == :column_ref))
          end

          def harmless_expr?(expr)
            case expr.kind
            when :AEXPR_OP then comparison?(expr) && atom?(expr.lexpr) && atom?(expr.rexpr)
            when :AEXPR_IN then atom?(expr.lexpr) && expr.rexpr.list.items.all? { atom?(it) }
            else false
            end
          end

          def comparison?(expr) = expr.name.size == 1 && COMPARISONS.include?(expr.name.first.string.sval)

          def atom?(node) = node && %i[column_ref param_ref a_const].include?(node.node)
        end
      end
    end
  end
end
