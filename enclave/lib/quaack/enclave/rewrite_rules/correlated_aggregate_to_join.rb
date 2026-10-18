# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "tree"
require_relative "../deparse"
require_relative "correlated_aggregate_to_join/grouped"

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
      # - No bare column in the statement has the name of a column of a
      #   derived table, which would make it ambiguous.
      #
      # Grouped reads the subquery. It gives one rewrite, with every
      # conjunct it can rewrite rewritten.
      class CorrelatedAggregateToJoin
        COMPARISONS = %w[= <> < <= > >=].freeze
        COLUMN = "quaack_agg"

        def name = "correlated_aggregate_to_join"

        def description
          "A WHERE condition that compares with a correlated avg, sum, min, or max subquery joins a derived " \
            "table that computes the aggregate once for each group instead."
        end

        def rewrites(parse, catalog, _literals = nil)
          tree = Deparse.copy(parse.tree)
          select = Tree.select(tree)
          found = select ? found(select, catalog) : []
          return [] if found.empty? || ambiguous?(tree, found) || volatile?(tree, catalog)

          names = Tree::Names.new(tree)
          found.each { join!(select, it, names.fresh(COLUMN)) }
          [Rewrite.new(tree:, assumptions: [])]
        end

        private

        # The Grouped::Found of each top-level WHERE conjunct the rule
        # rewrites.
        def found(select, catalog)
          items = Tree.from_items(select.from_clause)
          return [] if items.empty? || items.any? { it.name.nil? } || star?(select)

          Tree.conjuncts(select.where_clause).filter_map do |conjunct|
            node = compared(conjunct)
            Grouped.read(node, items, catalog) if node
          end
        end

        # The scalar subquery's Node of e op (subquery), either side, or nil.
        def compared(conjunct)
          expr = conjunct.a_expr if conjunct.node == :a_expr
          return unless expr&.kind == :AEXPR_OP && expr.name.size == 1 &&
                        COMPARISONS.include?(expr.name.first.string.sval)

          [expr.lexpr, expr.rexpr].find { it.node == :sub_link }
        end

        def star?(select)
          select.target_list.any? do |target|
            ref = target.res_target.val&.column_ref
            ref && ref.fields.size == 1 && ref.fields.first.node == :a_star
          end
        end

        # Whether a bare column anywhere in the statement has the name of a
        # derived table's column.
        def ambiguous?(tree, found)
          columns = found.flat_map { it.keys.map(&:first) } + [COLUMN]
          Tree.find_all(tree, PgQuery::ColumnRef).any? { columns.include?(Tree.bare_name(it)) }
        end

        def volatile?(tree, catalog)
          catalog.calls_volatile?(Deparse.faithfully(tree))
        rescue Deparse::Error
          true
        end

        # Adds the derived table to select's FROM, the join conditions to
        # its WHERE, and the derived table's aggregate in the subquery's
        # place.
        def join!(select, found, alias_name)
          select.from_clause << derived(found, alias_name)
          found.node.column_ref = column_ref(alias_name, COLUMN).column_ref
          joins = found.keys.map { |key, outer| equal(column_ref(alias_name, key), outer) }
          select.where_clause = Tree.all_of(Tree.conjuncts(select.where_clause) + joins)
        end

        # The derived table's FROM item, from a shape filled with the
        # subquery's own nodes. The names are double-quoted, so any name
        # reads as itself.
        def derived(found, alias_name)
          item = shape(found, alias_name)
          fill!(item.range_subselect.subquery.select_stmt, found)
          item
        end

        def shape(found, alias_name)
          columns = keys(found)
          sql = "SELECT FROM (SELECT #{columns}, NULL AS #{COLUMN} FROM t GROUP BY #{columns}) \"#{alias_name}\""
          PgQuery.parse(sql).tree.stmts.first.stmt.select_stmt.from_clause.first
        end

        def keys(found) = found.keys.map(&:first).uniq.map { %("#{quote(found.table.name)}"."#{quote(it)}") }.join(", ")

        def fill!(sub, found)
          sub.from_clause[0] = PgQuery::Node.new(range_var: found.table.range)
          sub.target_list[-1].res_target.val = PgQuery::Node.new(func_call: found.call)
          sub.where_clause = Tree.all_of(found.own)
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
