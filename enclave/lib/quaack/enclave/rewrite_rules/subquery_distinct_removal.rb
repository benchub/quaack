# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "subquery_distinct_removal/columns"
require_relative "subquery_distinct_removal/readers"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' subquery_distinct_removal. An ORM that
      # filters by another table's rows often dedupes or sorts the subquery
      # it filters by:
      #
      #   SELECT users.* FROM users WHERE users.id IN
      #     (SELECT DISTINCT enrollments.user_id FROM enrollments WHERE enrollments.course_id = $1)
      #
      # IN asks only whether some row of the subquery equals users.id, so
      # neither a second copy of a row nor the rows' order can change its
      # answer. The DISTINCT does nothing but work, and it also keeps
      # Postgres from pulling the subquery up into the outer query, where
      # it could plan a semi-join on enrollments' own index. Without it:
      #
      #   SELECT users.* FROM users WHERE users.id IN
      #     (SELECT enrollments.user_id FROM enrollments WHERE enrollments.course_id = $1)
      #
      # Readers says which SELECTs are read this way: the subquery of an
      # IN, = ANY, NOT IN, or <> ALL, and an arm under a UNION, INTERSECT,
      # or EXCEPT without ALL. A set operation can be one of them, with only
      # an ORDER BY to lose. From each, the rule removes what its reader
      # ignores:
      #
      # - A plain DISTINCT, not DISTINCT ON, when Columns.comparable? holds.
      #   Every row is still there, maybe more than once.
      # - A GROUP BY whose items are exactly the select list's columns, as
      #   a set, written the same way (name.column, or a bare column), with
      #   no HAVING, when Columns.comparable? holds. With no aggregate in
      #   the select list, that GROUP BY is a DISTINCT.
      # - Any ORDER BY. With no LIMIT or OFFSET, it changes only the order.
      #
      # It gives one rewrite per SELECT it can change, each from the
      # original, removing all of these that apply there, so the
      # generator's second pass changes two. It states no assumption: its
      # rewrite returns the same rows on any data the schema allows.
      #
      # It's conservative. It leaves a SELECT alone when:
      #
      # - It has a LIMIT, OFFSET, or FETCH, which picks rows by their count
      #   and order, or DISTINCT ON, which picks one row of each group by
      #   the ORDER BY.
      # - It has a locking clause, which SupportedSql refuses anyway.
      # - Its select list calls a set-returning, aggregate, or window
      #   function (Catalog#row_wise?), or might call a volatile one
      #   (Catalog#calls_volatile?).
      # - The statement isn't a SELECT.
      class SubqueryDistinctRemoval
        # The clauses one rewrite removes from one SELECT.
        Removal = Data.define(:select, :distinct, :group, :order) do
          def any? = distinct || group || order

          def remove!
            select.distinct_clause.clear if distinct
            if group
              select.group_clause.clear
              select.group_distinct = false
            end
            select.sort_clause.clear if order
          end
        end

        def name = "subquery_distinct_removal"

        def description
          "The subquery of an IN, = ANY, NOT IN, or <> ALL, or an arm under a UNION, INTERSECT, or EXCEPT " \
            "without ALL, loses its DISTINCT, its ORDER BY, and a GROUP BY of just its select list's columns, " \
            "since its reader ignores duplicates and order."
        end

        def rewrites(parse, catalog, _literals = nil)
          Array.new(removals(parse.tree, catalog).size) do |i|
            tree = Deparse.copy(parse.tree)
            removals(tree, catalog)[i].remove!
            Rewrite.new(tree:, assumptions: [])
          end
        end

        private

        # What the rule removes from each SELECT of tree it can change, in
        # tree order.
        def removals(tree, catalog)
          return [] unless Tree.select(tree)

          Readers.in(tree).filter_map { removal(it, catalog) }.select(&:any?)
        end

        def removal(select, catalog)
          return unless unlimited?(select) && plain_list?(select, catalog)

          distinct = distinct?(select)
          group = grouped?(select)
          columns = (distinct || group) && Columns.comparable?(select, catalog)
          Removal.new(select:, distinct: distinct && columns, group: group && columns, order: select.sort_clause.any?)
        end

        # Whether select has no LIMIT, OFFSET, locking clause, or DISTINCT
        # ON.
        def unlimited?(select)
          select.limit_count.nil? && select.limit_offset.nil? && select.locking_clause.empty? &&
            select.distinct_clause.all? { it.node.nil? }
        end

        # Whether select's select list gives one value per row and calls no
        # volatile function.
        def plain_list?(select, catalog)
          list = PgQuery::SelectStmt.new(target_list: select.target_list.map { Deparse.copy(it) },
                                         limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
          catalog.row_wise?(select.target_list.to_a) && !catalog.calls_volatile?(Deparse.statement(list))
        rescue Deparse::Error
          false
        end

        def distinct?(select) = select.distinct_clause.size == 1

        def grouped?(select)
          return false if select.group_clause.empty? || select.having_clause

          select.group_clause.to_set { Columns.names(it) } ==
            select.target_list.to_set { Columns.names(it.res_target.val) }
        end
      end
    end
  end
end
