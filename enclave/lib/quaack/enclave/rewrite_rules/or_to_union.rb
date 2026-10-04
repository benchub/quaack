# frozen_string_literal: true

require "pg_query"
require_relative "tree"
require_relative "or_to_union/arms"
require_relative "or_to_union/reads"
require_relative "or_to_union/union"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules's or_to_union. The planner can't use an index for
      # either arm of an OR whose arms are about different tables, or are
      # subqueries:
      #
      #   SELECT a.id, a.title FROM a JOIN s ON s.a_id = a.id
      #   WHERE s.user_id = $1 AND (EXISTS (SELECT 1 FROM cp WHERE cp.s_id = s.id) OR a.id IN ($2, $3))
      #
      # So the rule runs the query's FROM and WHERE once per arm, each with
      # only that arm in the OR's place, and reads their UNION in place of
      # the tables:
      #
      #   SELECT arms_1.id_1 AS id, arms_1.title_1 AS title
      #   FROM (SELECT a.id AS id_1, a.title AS title_1, s.id AS id_2 FROM a JOIN s ON s.a_id = a.id
      #         WHERE s.user_id = $1 AND EXISTS (SELECT 1 FROM cp WHERE cp.s_id = s.id)
      #         UNION
      #         SELECT a.id AS id_1, a.title AS title_1, s.id AS id_2 FROM a JOIN s ON s.a_id = a.id
      #         WHERE s.user_id = $1 AND a.id IN ($2, $3)) arms_1
      #
      # Why that's sound. An OR is true exactly when one of its arms is
      # true, whatever is NULL, so the rows of the join that pass the WHERE
      # are those that pass it with one arm or with another. UNION then has
      # to remove a row exactly when it's one row of the join that two arms
      # both passed. Each arm gives a key of every FROM table, unique and
      # not null, so two rows of the join always differ in a key and are
      # never merged, and one row of the join gives the same values in
      # every arm and always is. The UNION is therefore the rows of the
      # join that pass the WHERE, each once, with every column the rest of
      # the query uses. The select list, DISTINCT, ORDER BY, LIMIT, and
      # OFFSET stay outside, and read those rows as they read the join's.
      # So an aggregate counts each row once, two rows that only look alike
      # in the select list both stay, and the order and the limit apply to
      # the whole UNION. Output columns keep their names.
      #
      # It gives one rewrite per OR it can split, each splitting only that
      # OR, and each stating a key of every FROM table unique and not null.
      #
      # It's conservative. It fires only when all of this holds, and
      # otherwise gives nothing:
      #
      # - The query is one SELECT, with no GROUP BY, HAVING, window
      #   function, WINDOW, DISTINCT ON, locking clause, WITH, or INTO. An
      #   aggregate with no GROUP BY is fine, and so is a plain DISTINCT.
      # - The OR is one of the conditions its WHERE ANDs together, and its
      #   arms read different tables or subqueries (see Arms).
      # - The FROM and every column used outside the WHERE are ones Reads
      #   takes, and the catalog proves a key of every table.
      # - Outside the WHERE there's no subquery, and each select-list
      #   entry keeps its name: it has an AS, or it's a column, a function
      #   call, or an operator, or it has no column in it. A cast of a
      #   column, say, is named for the column, which the UNION renames.
      #
      # A volatile function would run once per arm, but volatility refuses a
      # query that calls one, so none gets here.
      class OrToUnion
        # A select-list entry of one of these is named for itself, not for
        # a column inside it.
        SELF_NAMED = %i[column_ref func_call a_expr].freeze

        def name = "or_to_union"

        def description
          "An OR whose arms read different tables or subqueries becomes a UNION of one query per arm, which the " \
            "rest of the query reads in place of its tables."
        end

        def rewrites(parse, catalog, _literals = nil)
          select = Tree.select(parse.tree)
          reads = Reads.of(select, catalog) if select && plain?(select) && movable?(select)
          return [] unless reads

          Arms.splittable(select).map do |index|
            Rewrite.new(tree: Union.new(parse.tree, index, reads).tree, assumptions: reads.assumptions)
          end
        end

        private

        # A set operation needs no check here: it has no FROM of its own,
        # which Reads refuses.
        def plain?(select)
          [select.with_clause, select.into_clause, select.having_clause].none? &&
            [select.group_clause, select.window_clause, select.locking_clause].all?(&:empty?) &&
            select.distinct_clause.all? { it.node.nil? }
        end

        # Whether what's outside the WHERE can read the UNION instead.
        def movable?(select)
          outside = Reads.outside(select)
          Tree.find(outside, PgQuery::SubLink).empty? && Tree.find(outside, PgQuery::FuncCall).none?(&:over) &&
            select.target_list.all? { named?(it.res_target) }
        end

        def named?(target)
          !target.name.empty? || SELF_NAMED.include?(target.val.node) ||
            Tree.find(target.val, PgQuery::ColumnRef).empty?
        end
      end
    end
  end
end
