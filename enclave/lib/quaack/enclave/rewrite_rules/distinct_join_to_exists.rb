# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "distinct_join_to_exists/query"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' distinct_join_to_exists. An ORM that wants the rows
      # of one table that have a match in another joins them and removes
      # the duplicates the join makes:
      #
      #   SELECT DISTINCT t.* FROM t JOIN r ON r.t_id = t.id WHERE t.x = $1 AND r.y = $2 ORDER BY t.id LIMIT 20
      #
      # which builds every joined row before it throws most away. When the
      # select list holds a unique, not-null key of t, two rows of t never
      # give the same output row, so DISTINCT leaves exactly one row for
      # each row of t that has any match, which is what EXISTS asks:
      #
      #   SELECT t.* FROM t WHERE t.x = $1 AND EXISTS (SELECT 1 FROM r WHERE r.t_id = t.id AND r.y = $2)
      #     ORDER BY t.id LIMIT 20
      #
      # Without the key it would be wrong: DISTINCT would also merge two
      # rows of t that are equal in the selected columns, and the EXISTS
      # form keeps both.
      #
      # The other tables all go in one EXISTS, under the names they had,
      # with every condition that reads any of them, whole, so an OR across
      # the kept table and another is asked as it was. The conditions on
      # the kept table alone stay in the WHERE. Nothing is renamed: each
      # FROM item has a name of its own, and no other subquery is there to
      # take a name. A column written name.column reads the table it read
      # before. A bare column belongs to the one FROM table that has it
      # (see Columns), so in the EXISTS no inner table has it unless it was
      # that table's, and outside it only the kept table is left.
      #
      # It gives one rewrite, stating the key unique and each of its
      # columns not null. The key is one the catalog proves both of, all
      # of its columns selected (see Query#key): the fewest columns, then
      # the one that ends first in the select list. A star stands for the
      # table's columns, in order.
      #
      # It's conservative. It fires only when all of this holds, and
      # otherwise gives nothing:
      #
      # - The query is one SELECT with a plain DISTINCT: no DISTINCT ON,
      #   GROUP BY, HAVING, WINDOW, locking clause, WITH, or set operation.
      # - Its FROM holds two or more tables and nothing else, each
      #   schema-qualified (so not a CTE), read without ONLY and without
      #   column aliases, under a name of its own, joined only by plain
      #   inner or cross joins: no outer join, NATURAL, USING, or join
      #   alias. So the ONs are more WHERE conditions. An outer join keeps
      #   rows with no match, which EXISTS drops.
      # - Every column in the select list and the ORDER BY is a column of
      #   the kept table, or its star. An expression of them, such as a
      #   COLLATE, a cast, or a function call, gives one value for each of
      #   the kept table's rows, so it's taken, but only if each function
      #   and operator it could call gives one value per row (see
      #   Catalog#row_wise?): a window function counts the join's rows, and
      #   a set-returning one gives several rows for one of the table's,
      #   which DISTINCT merges.
      # - Nothing in the query could call a volatile function
      #   (Catalog#calls_volatile?): the rewrite calls it for other rows.
      # - With a LIMIT or OFFSET, the ORDER BY holds every column of the key
      #   by name.column. That makes the order total, so both queries give the
      #   same rows. Without it the original may give any of several
      #   answers, and a test that compares the two would call a sound
      #   rewrite wrong. A bare name there may be an output column's, as in
      #   ORDER BY x for SELECT a.title AS x, so it doesn't count.
      # - Every column in the conditions is name.column or a bare column
      #   of one FROM table, never a star.
      # - A subquery is only in a condition that reads the kept table alone,
      #   which stays in the WHERE as it was. The kept table is still there
      #   under its name, and a subquery's own columns are its own, so each
      #   column reads what it read before. Its FROM is plain tables, and a
      #   column of it that reads the outer query reads the kept table: a
      #   correlated column of another table would have nothing to read
      #   (see Columns). None is in the select list, ORDER BY, LIMIT, or
      #   OFFSET.
      class DistinctJoinToExists
        def name = "distinct_join_to_exists"

        def description
          "A SELECT DISTINCT of one table's columns over a join, with a unique, not-null key of that table among " \
            "them, becomes that table alone with an EXISTS on the other tables, and no DISTINCT."
        end

        def rewrites(parse, catalog, _literals = nil)
          tree = Deparse.copy(parse.tree)
          select = Tree.select(tree)
          query = Query.read(select, catalog) if select && distinct?(select)
          key = query&.key(catalog)
          return [] unless key && catalog.row_wise?(query.shown) && !catalog.calls_volatile?(Deparse.faithfully(tree))

          query.rewrite!(select)
          [Rewrite.new(tree:, assumptions: query.assumptions(key))]
        end

        private

        # Whether select has a plain DISTINCT and none of the clauses the
        # rule refuses. A set operation has no DISTINCT of its own: its
        # arms hold theirs.
        def distinct?(select)
          select.distinct_clause.size == 1 && select.distinct_clause.first.node.nil? && ungrouped?(select) &&
            select.locking_clause.empty? && select.with_clause.nil?
        end

        def ungrouped?(select)
          select.group_clause.empty? && select.having_clause.nil? && select.window_clause.empty?
        end
      end
    end
  end
end
