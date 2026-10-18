# frozen_string_literal: true

module Quaack
  module Driver
    class WinnerSummary
      module Input
        # Each rule's one-line purpose, from DESIGN.md's transform list, as
        # fixed text the driver holds: the LLM gets it by the rule's name,
        # so it can say what the rewrite changed without guessing.
        RULE_PURPOSES = {
          "implied_predicate_removal" => "Removes a redundant predicate in a WHERE or inner-join ON that an " \
                                         "equality on the same column already proves.",
          "transitive_predicate_copy" => "Copies a filter on one side of a column equality to the other side, so " \
                                         "both tables can be filtered.",
          "shared_scan_cte" => "Reads a table that appears more than once in one FROM only once, through a " \
                               "MATERIALIZED CTE of the conditions every copy shares.",
          "key_in_self_join" => "Turns an IN subquery that reads the outer table again by a unique, not-null key " \
                                "into that table's own predicates, plus an EXISTS on what's left of the subquery.",
          "or_to_union" => "Splits an OR whose arms test different tables or subqueries into a UNION of one query " \
                           "per arm, so each arm can be planned on its own.",
          "not_in_to_not_exists" => "Turns a NOT IN subquery over columns that are all not null into a NOT EXISTS " \
                                    "correlated on each pair of columns.",
          "existence_in_flip" => "Turns an existence check under LIMIT 1 inside out: the uncorrelated IN " \
                                 "subquery's table drives, and the rest becomes a correlated EXISTS.",
          "distinct_join_to_exists" => "Turns a SELECT DISTINCT of one table's columns over a join into that table " \
                                       "alone with an EXISTS on the other tables, and no DISTINCT.",
          "cte_hoist_dedupe" => "Merges CTEs with the same body into one top-level CTE that every reference reads.",
          "union_outer_filter_removal" => "Removes a filter on a UNION subquery's output when every arm already " \
                                          "applies it.",
          "unused_join_removal" => "Removes an inner join to a table the query reads nowhere else, on a validated " \
                                   "foreign key whose columns are not null.",
          "polymorphic_key_copy" => "Where a joined parent is filtered to one Rails polymorphic type and id, " \
                                    "filters the child's own column for that type to the same id.",
          "subquery_distinct_removal" => "Removes a DISTINCT, an ORDER BY, or a GROUP BY of just the select list's " \
                                         "columns from a subquery whose reader ignores duplicates and order, such " \
                                         "as an IN subquery or a UNION arm.",
          "distinct_key_removal" => "Removes a DISTINCT that can't remove a row: the select list holds a unique, " \
                                    "not-null key of the first table, and each join matches at most one row.",
          "cte_fence_removal" => "Writes a CTE that Postgres would store, because it's MATERIALIZED or read more " \
                                 "than once, as NOT MATERIALIZED, so each reader's conditions can reach its tables.",
          "left_join_to_inner" => "Turns a LEFT JOIN on a validated foreign key whose columns are not null into an " \
                                  "inner join, which Postgres can reorder, so the joined table can drive.",
          "count_to_exists" => "Turns a count subquery that only asks whether any row matches, such as " \
                               "count(*) > 0 or count(*) = 0, into an EXISTS or a NOT EXISTS, which can stop at " \
                               "the first match.",
          "count_distinct_to_subquery" => "Counts the rows of a SELECT DISTINCT of the GROUP BY columns and the " \
                                          "counted value, in place of a count(DISTINCT), so Postgres can hash " \
                                          "instead of sorting inside the aggregate.",
          "subquery_order_removal" => "Removes an ORDER BY with no LIMIT or OFFSET from a subquery in FROM or a CTE " \
                                      "when nothing that reads it depends on that order, such as a count of its rows.",
          "union_to_union_all" => "Turns a UNION whose rows can't repeat into a UNION ALL: each arm selects a " \
                                  "unique, not-null key of its table and a tag that differs from every other arm's.",
          "coalesce_comparison_split" => "Splits a COALESCE of a column compared with a value into a comparison of " \
                                         "the column and a test for its NULLs, which an index on the column can serve.",
          "correlated_aggregate_to_join" => "Computes a correlated avg, sum, min, or max subquery once for each " \
                                            "group, in a grouped derived table that the query joins."
        }.freeze
      end
    end
  end
end
