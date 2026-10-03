# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "tree"
require_relative "distinct_join_to_exists/query"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md 6c's distinct_join_to_exists. An ORM that wants the rows
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
      # the kept table alone stay in the WHERE. Nothing is renamed: every
      # column is written name.column, each FROM item has a name of its
      # own, and no other subquery is there to take a name, so each column
      # reads the table it read before.
      #
      # It gives one rewrite, stating the key unique and not null. The key
      # is the first selected column the catalog proves both of (see
      # Catalog); a star stands for the table's columns, in order.
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
      # - Each select-list item is name.column or name.*, all of one
      #   table, the kept one. An expression isn't taken, even of that
      #   table: a window function counts the join's rows, and a
      #   set-returning one gives several rows for one of the table's,
      #   which DISTINCT merges.
      # - Each ORDER BY item is name.column of the kept table, or a
      #   position in the select list.
      # - With a LIMIT or OFFSET, the ORDER BY holds the key by name.
      #   That makes the order total, so both queries give the same rows.
      #   Without it the original may give any of several answers, and a
      #   test that compares the two would call a sound rewrite wrong.
      # - Every column in the conditions is written name.column, where
      #   name is one of the FROM's tables, and nowhere is there a subquery.
      # - A key of one column. A key of several isn't looked for in v1.
      class DistinctJoinToExists
        def name = "distinct_join_to_exists"

        def description
          "A SELECT DISTINCT of one table's columns over a join, with a unique, not-null key of that table among " \
            "them, becomes that table alone with an EXISTS on the other tables, and no DISTINCT."
        end

        def rewrites(parse, catalog)
          tree = Deparse.copy(parse.tree)
          select = Tree.select(tree)
          query = Query.read(select) if select && distinct?(select)
          key = query&.key(catalog)
          return [] unless key

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
