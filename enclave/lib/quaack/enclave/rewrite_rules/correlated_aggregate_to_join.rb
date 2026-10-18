# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "tree"
require_relative "../deparse"
require_relative "or_to_union/arms"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' correlated_aggregate_to_join. A query that
      # compares each row with an aggregate of its group often writes the
      # aggregate as a correlated subquery:
      #
      #   SELECT o.id FROM orders o
      #   WHERE o.total > (SELECT avg(o2.total) FROM orders o2 WHERE o2.customer_id = o.customer_id)
      #
      # Postgres runs that subquery once per outer row, and reads the whole
      # group each time. The rule computes each group's aggregate once, in
      # a grouped derived table, and joins it:
      #
      #   SELECT o.id FROM orders o,
      #     (SELECT o2.customer_id, avg(o2.total) AS quaack_agg FROM orders o2 GROUP BY o2.customer_id) quaack_agg_1
      #   WHERE o.total > quaack_agg_1.quaack_agg AND quaack_agg_1.customer_id = o.customer_id
      #
      # avg, sum, min, and max give NULL over no rows. So an outer row with
      # no group, or a NULL correlation column, gets a NULL aggregate in the
      # original, which makes the comparison NULL, and no join partner in
      # the rewrite. The WHERE drops it either way. Each key has one group,
      # so no row repeats. It rests on no catalog fact, so it states none.
      #
      # It rewrites a top-level conjunct of the statement's WHERE only when
      # all of this holds:
      #
      # - The conjunct is e op (subquery), either side, where op is =, <>,
      #   <, <=, >, or >=.
      # - The subquery reads one plain table, has no GROUP BY, HAVING,
      #   DISTINCT, ORDER BY, LIMIT, WINDOW, WITH, set operation, or nested
      #   subquery, and selects only avg, sum, min, or max of one of its
      #   table's columns, written name.column, with no DISTINCT, FILTER,
      #   ORDER BY, or OVER.
      # - Each of its conjuncts either reads only its table, every column
      #   written name.column, or is name.k = outer.c, either way round,
      #   where outer is a name of the outer SELECT's own FROM. There is at
      #   least one of the latter. k and c have one type, which hashes and
      #   sorts as its equality does, and a deterministic collation, so
      #   GROUP BY puts together just the rows the equality would match.
      # - The derived table runs the subquery's conditions, and the
      #   aggregate, on every row of the table, not just those of the groups
      #   the original reads. So nothing in its conditions can raise on
      #   some rows (OrToUnion::Arms.raises?), and sum and avg take only an
      #   integer or numeric column, which can't overflow. min and max never
      #   raise.
      # - The outer SELECT's select list has no bare *, which would show
      #   the derived table's columns, and nothing in the statement could
      #   call a volatile function (Catalog#calls_volatile?), which would
      #   run another number of times.
      #
      # It gives one rewrite, with every conjunct it can rewrite rewritten.
      class CorrelatedAggregateToJoin
        AGGREGATES = %w[avg sum min max].freeze
        COMPARISONS = %w[= <> < <= > >=].freeze
        # The types sum and avg take without a chance of overflow.
        SUMMABLE = %w[smallint integer bigint numeric].freeze
        COLUMN = "quaack_agg"

        # One conjunct to rewrite: the Node that holds the subquery, its
        # table's name and RangeVar, the aggregate call, the conditions
        # that read only the table, and [k, outer ColumnRef] for each
        # correlation.
        Found = Data.define(:node, :name, :table, :call, :own, :keys)

        def name = "correlated_aggregate_to_join"

        def description
          "A WHERE condition that compares with a correlated avg, sum, min, or max subquery joins a derived " \
            "table that computes the aggregate once for each group instead."
        end

        def rewrites(parse, catalog, _literals = nil)
          tree = Deparse.copy(parse.tree)
          select = Tree.select(tree)
          return [] unless select && !select.from_clause.empty? && !star?(select)

          items = Tree.from_items(select.from_clause)
          return [] if items.any? { it.name.nil? }

          found = Tree.conjuncts(select.where_clause).filter_map { found(it, items, catalog) }
          return [] if found.empty? || volatile?(tree, catalog)

          names = Tree::Names.new(tree)
          found.each { join!(select, it, names.fresh(COLUMN)) }
          [Rewrite.new(tree:, assumptions: [])]
        end

        private

        def star?(select)
          select.target_list.any? do |target|
            ref = target.res_target.val&.column_ref
            ref && ref.fields.size == 1 && ref.fields.first.node == :a_star
          end
        end

        def volatile?(tree, catalog)
          catalog.calls_volatile?(Deparse.faithfully(tree))
        rescue Deparse::Error
          true
        end

        # The Found of a conjunct, or nil.
        def found(conjunct, items, catalog)
          expr = conjunct.a_expr if conjunct.node == :a_expr
          return unless expr&.kind == :AEXPR_OP && expr.name.size == 1 &&
                        COMPARISONS.include?(expr.name.first.string.sval)

          node = [expr.lexpr, expr.rexpr].find { it.node == :sub_link }
          read(node, items, catalog) if node && node.sub_link.sub_link_type == :EXPR_SUBLINK
        end

        def read(node, items, catalog)
          select = node.sub_link.subselect.select_stmt
          return unless select && plain?(select) && select.from_clause.size == 1

          table = select.from_clause.first.range_var
          return unless table && Tree.plain_table?(table)

          name = Tree.refname(table)
          call = aggregate(select, name, table, catalog)
          return unless call && !OrToUnion::Arms.raises?(select.where_clause, catalog)

          own, keys = split(select.where_clause, name, table, items, catalog)
          # A key named as the aggregate's column would make it ambiguous.
          return unless own && keys.any? && keys.none? { it.first == COLUMN }

          Found.new(node:, name:, table:, call:, own:, keys:)
        end

        def plain?(select)
          Tree.plain_select?(select) && select.distinct_clause.empty? && select.target_list.size == 1 &&
            select.op == :SETOP_NONE && Tree.find_all(select.where_clause, PgQuery::SubLink).empty?
        end

        # The select list's FuncCall, if it's one of AGGREGATES of a column
        # of the table it can take.
        def aggregate(select, name, table, catalog)
          call = select.target_list.first.res_target.val.func_call
          return unless call && call.funcname.size == 1 && AGGREGATES.include?(call.funcname.first.string.sval)
          return unless call.agg_filter.nil? && call.over.nil? && call.agg_order.empty? && !call.agg_distinct &&
                        !call.agg_star && call.args.size == 1

          column = own_column(call.args.first, name)
          info = column && catalog.column_info(table.schemaname, table.relname, column)
          call if info && (%w[min max].include?(call.funcname.first.string.sval) || SUMMABLE.include?(info.base_type))
        end

        # The column node names, if it's written name.column, or nil.
        def own_column(node, name)
          qualifier, column = Tree.qualified(node.column_ref) if node.node == :column_ref
          column if qualifier == name
        end

        # [the conditions that read only the table, the correlations], or
        # nil if a condition is neither.
        def split(where, name, table, items, catalog)
          own = []
          keys = []
          Tree.conjuncts(where).each do |conjunct|
            key = correlation(conjunct, name, table, items, catalog)
            if key then keys << key
            elsif own?(conjunct, name) then own << conjunct
            else return
            end
          end
          [own, keys]
        end

        # Whether every column conjunct reads is written name.column.
        def own?(conjunct, name)
          Tree.find_all(conjunct, PgQuery::ColumnRef).all? { Tree.qualified(it)&.first == name }
        end

        # [k, the outer ColumnRef] if conjunct is name.k = outer.c, either
        # way round, of one comparable type and a deterministic collation.
        def correlation(conjunct, name, table, items, catalog)
          expr = conjunct.a_expr if conjunct.node == :a_expr
          return unless expr&.kind == :AEXPR_OP && expr.name.size == 1 && expr.name.first.string.sval == "="

          sides = [expr.lexpr, expr.rexpr]
          sides.reverse! unless own_column(sides.first, name)
          key = own_column(sides.first, name)
          outer = outer_column(sides.last, name, items)
          return unless key && outer && same_type?([table.schemaname, table.relname, key], outer[1], catalog)

          [key, sides.last.column_ref]
        end

        # [the ColumnRef, [schema, table, column]] for outer.c, where outer
        # is a plain table of the outer FROM that the subquery's table
        # doesn't hide.
        def outer_column(node, name, items)
          qualifier, column = Tree.qualified(node.column_ref) if node.node == :column_ref
          return unless qualifier && qualifier != name

          named = items.select { it.name == qualifier }
          table = named.first.table if named.size == 1
          [node.column_ref, [table.schemaname, table.relname, column]] if table && Tree.plain_table?(table)
        end

        def same_type?(key, outer, catalog)
          one = catalog.column_info(*key)
          other = catalog.column_info(*outer)
          comparable = catalog.columns(key[0], key[1]).find { it.name == key[2] }&.comparable
          one && other && comparable && one.type == other.type && one.collation == other.collation &&
            one.deterministic
        end

        # Adds the derived table to select's FROM, the join conditions to
        # its WHERE, and the derived table's aggregate in the subquery's
        # place.
        def join!(select, found, alias_name)
          keys = found.keys.map(&:first).uniq
          derived = PgQuery.parse(derived_sql(found, keys, alias_name)).tree.stmts.first.stmt.select_stmt
          sub = derived.from_clause.first.range_subselect.subquery.select_stmt
          sub.from_clause[0] = PgQuery::Node.new(range_var: found.table)
          sub.target_list[-1].res_target.val = PgQuery::Node.new(func_call: found.call)
          sub.where_clause = Tree.all_of(found.own)
          select.from_clause << derived.from_clause.first

          found.node.column_ref = column_ref(alias_name, COLUMN).column_ref
          joins = found.keys.map { |key, outer| equal(column_ref(alias_name, key), outer) }
          select.where_clause = Tree.all_of(Tree.conjuncts(select.where_clause) + joins)
        end

        # The derived table's shape, for join! to fill with the subquery's
        # own nodes. The names are double-quoted, so any name reads as
        # itself.
        def derived_sql(found, keys, alias_name)
          columns = keys.map { %("#{quote(found.name)}"."#{quote(it)}") }.join(", ")
          "SELECT FROM (SELECT #{columns}, NULL AS \"#{COLUMN}\" FROM t GROUP BY #{columns}) \"#{alias_name}\""
        end

        def quote(name) = name.gsub('"', '""')

        def column_ref(qualifier, column)
          PgQuery::Node.new(column_ref: PgQuery::ColumnRef.new(fields: [Tree.string(qualifier), Tree.string(column)]))
        end

        def equal(left, right)
          PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind: :AEXPR_OP, name: [Tree.string("=")], lexpr: left,
                                                        rexpr: PgQuery::Node.new(column_ref: right)))
        end
      end
    end
  end
end
