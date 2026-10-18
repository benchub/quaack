# frozen_string_literal: true

require "pg_query"
require_relative "../tree"
require_relative "../or_to_union/arms"
require_relative "../count_to_exists/counted"

module Quaack
  module Enclave
    module RewriteRules
      class CorrelatedAggregateToJoin
        # Reads a correlated aggregate subquery the rule can compute once
        # per group (see CorrelatedAggregateToJoin).
        module Grouped
          AGGREGATES = %w[avg sum min max].freeze
          # The aggregates that never raise.
          PICKS = %w[min max].freeze
          # The types sum and avg take without a chance of overflow.
          SUMMABLE = %w[smallint integer bigint numeric].freeze

          # The subquery's one table: the name it goes by, and its RangeVar.
          Table = Data.define(:name, :range) do
            def column(column) = [range.schemaname, range.relname, column]
          end

          # One subquery to rewrite: the Node that holds it, its Table, the
          # aggregate call, the conditions that read only the table, and
          # [k, outer ColumnRef] for each correlation.
          Found = Data.define(:node, :table, :call, :own, :keys)

          module_function

          # The Found of a scalar subquery's Node, or nil. items are the
          # outer FROM's Tree::Items.
          def read(node, items, catalog)
            select = subquery(node)
            table = table(select) if select
            call = aggregate(select, table, catalog) if table
            return unless call && !OrToUnion::Arms.raises?(select.where_clause, catalog)

            own, keys = split(Tree.conjuncts(select.where_clause), table, items, catalog)
            Found.new(node:, table:, call:, own:, keys:) if own && keys.any?
          end

          # The SELECT of a scalar subquery that reads one item and selects
          # one column, with no WITH, DISTINCT, GROUP BY, HAVING, WINDOW,
          # ORDER BY, LIMIT, set operation, or subquery in its WHERE, or nil.
          def subquery(node)
            select = CountToExists::Counted.one_row(node.sub_link)
            select if select && select.op == :SETOP_NONE && select.from_clause.size == 1 &&
                      Tree.find_all(select.where_clause, PgQuery::SubLink).empty?
          end

          def table(select)
            range = select.from_clause.first.range_var
            Table.new(name: Tree.refname(range), range:) if range && Tree.plain_table?(range)
          end

          # The select list's FuncCall, if it's one of AGGREGATES of a
          # column of the table it can take.
          def aggregate(select, table, catalog)
            call = select.target_list.first.res_target.val.func_call
            function = function(call)
            column = own_column(call.args.first, table.name) if function
            info = catalog.column_info(*table.column(column)) if column
            call if info && (PICKS.include?(function) || SUMMABLE.include?(info.base_type))
          end

          # The name of one of AGGREGATES, if call is a plain call of it, or
          # nil: one argument, and no DISTINCT, FILTER, ORDER BY, or OVER.
          def function(call)
            name = call.funcname.first.string.sval if call && call.funcname.size == 1
            name if AGGREGATES.include?(name) && !call.agg_star && CountToExists::Counted.plain_call?(call)
          end

          # The column node names, if it's written name.column, or nil.
          def own_column(node, name)
            qualifier, column = Tree.qualified(node.column_ref) if node.node == :column_ref
            column if qualifier == name
          end

          # [the conditions that read only the table, the correlations], or
          # nil if a condition is neither.
          def split(conjuncts, table, items, catalog)
            keys = conjuncts.map { correlation(it, table, items, catalog) }
            own = conjuncts.zip(keys).filter_map { |conjunct, key| conjunct unless key }
            [own, keys.compact] if own.all? { own?(it, table.name) }
          end

          # Whether every column conjunct reads is written name.column.
          def own?(conjunct, name)
            Tree.find_all(conjunct, PgQuery::ColumnRef).all? { Tree.qualified(it)&.first == name }
          end

          # [k, the outer ColumnRef] if conjunct is name.k = outer.c, either
          # way round, of one comparable type and a deterministic collation.
          def correlation(conjunct, table, items, catalog)
            key, other = keyed(equality(conjunct), table.name)
            outer = outer_column(other, table.name, items) if key
            [key, other.column_ref] if outer && same_type?(table.column(key), outer, catalog)
          end

          # [left, right] of a bare =, or nil.
          def equality(conjunct)
            expr = conjunct.a_expr if conjunct.node == :a_expr
            [expr.lexpr, expr.rexpr] if expr&.kind == :AEXPR_OP && expr.name.size == 1 &&
                                        expr.name.first.string.sval == "="
          end

          # [k, the other side] if one side is name.k, or nil.
          def keyed(sides, name)
            sides = sides&.reverse unless sides && own_column(sides.first, name)
            key = own_column(sides.first, name) if sides
            [key, sides.last] if key
          end

          # [schema, table, column] for outer.c, where outer is a plain
          # table of the outer FROM that the subquery's table doesn't hide.
          def outer_column(node, name, items)
            qualifier, column = Tree.qualified(node.column_ref) if node.node == :column_ref
            table = outer_table(items, qualifier) if qualifier && qualifier != name
            [table.schemaname, table.relname, column] if table
          end

          def outer_table(items, qualifier)
            named = items.select { it.name == qualifier }
            table = named.first.table if named.size == 1
            table if table && Tree.plain_table?(table)
          end

          # Whether the two columns have one type, which hashes and sorts as
          # its equality compares, and one deterministic collation, so
          # GROUP BY puts together just the rows the equality matches.
          def same_type?(key, outer, catalog)
            one = catalog.column_info(*key)
            other = catalog.column_info(*outer)
            comparable = catalog.columns(key[0], key[1]).find { it.name == key[2] }&.comparable
            one && other && comparable && one.type == other.type && one.collation == other.collation &&
              one.deterministic
          end
        end
      end
    end
  end
end
