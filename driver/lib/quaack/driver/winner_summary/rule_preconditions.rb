# frozen_string_literal: true

module Quaack
  module Driver
    class WinnerSummary
      module Input
        # What must hold for each rule to apply, from the rule's code and its
        # page in docs/transforms (20261010-37), as fixed text the driver
        # holds. A rule that made the winner applied, so its precondition
        # held for this query: the LLM states it as the feature of the query
        # or schema that made the rewrite possible, and can't invent one.
        RULE_PRECONDITIONS = {
          "implied_predicate_removal" => "The same SELECT has an equality on a column, col = c, in the top-level AND " \
                                         "of its WHERE or an inner join's ON, beside another condition on that " \
                                         "column, such as an IN list, a range, or a duplicate, that the equality " \
                                         "already proves.",
          "transitive_predicate_copy" => "Two columns are equal in the top-level AND of a WHERE or inner-join ON, " \
                                         "and one of them has a filter, an IN list or a range against constants, " \
                                         "that the other side doesn't have yet.",
          "shared_scan_cte" => "One FROM reads the same table more than once, and every copy has at least one " \
                               "filter condition on its own columns in common with the others.",
          "key_in_self_join" => "An IN subquery reads the outer table again and selects the column it is tested " \
                                "against, and that column is a key the catalog proves unique and not null, so each " \
                                "outer row matches at most itself.",
          "or_to_union" => "A top-level OR has arms that read different tables or subqueries, and every FROM table " \
                           "has a unique key whose columns are all not null, so a UNION of one query per arm drops " \
                           "only rows both arms return.",
          "not_in_to_not_exists" => "A NOT IN subquery's tested and selected columns are all ones the catalog proves " \
                                    "not null, so NOT IN and NOT EXISTS mean the same thing.",
          "existence_in_flip" => "The query only checks whether any row exists: its select list is all constants, " \
                                 "under LIMIT 1, and a top-level condition is an uncorrelated IN subquery.",
          "distinct_join_to_exists" => "A SELECT DISTINCT over inner joins selects only one table's columns, " \
                                       "including every column of a unique key of that table that are all not " \
                                       "null, so the join can only repeat rows that DISTINCT then removes.",
          "cte_hoist_dedupe" => "The query has two or more CTEs with the same body, column names, and " \
                                "materialization option, none correlated or volatile.",
          "union_outer_filter_removal" => "A filter on a UNION subquery's output columns is one every arm's WHERE " \
                                          "already applies to the column it outputs.",
          "unused_join_removal" => "An inner join is to a table the query reads nowhere else, on a validated, " \
                                   "enforced foreign key whose joining columns are not null, so the join can " \
                                   "neither drop nor repeat a row.",
          "polymorphic_key_copy" => "A child table joins a parent filtered to one Rails polymorphic type and id, " \
                                    "and the child has its own column for that type's id, which QUAACK checked " \
                                    "holds the same id in the data.",
          "subquery_distinct_removal" => "The subquery of an IN, = ANY, NOT IN, or <> ALL, or an arm under a UNION, " \
                                         "INTERSECT, or EXCEPT without ALL, has a DISTINCT, an ORDER BY, or a GROUP " \
                                         "BY of just its select list's columns, and no LIMIT or OFFSET, so its " \
                                         "reader can't see the duplicates or the order those clauses change.",
          "distinct_key_removal" => "A SELECT DISTINCT selects every column of a unique, not-null key of its first " \
                                    "table, and each of its inner or left joins is on every column of a unique " \
                                    "key of the joined table, so no two of its rows can be equal.",
          "cte_fence_removal" => "The query has a CTE written AS MATERIALIZED, or a plain CTE it reads more than " \
                                 "once, whose body calls no volatile function, and no condition that could reach " \
                                 "the body's tables can raise an error.",
          "left_join_to_inner" => "A LEFT JOIN is on a validated, enforced foreign key from a table on its left " \
                                  "side that no outer join there can fill with NULLs, and the foreign key's " \
                                  "columns are not null, so every left row has a match and the join extends no row " \
                                  "with NULLs.",
          "count_to_exists" => "A scalar subquery selects only count(*), or a count of a column of one of its " \
                               "own tables, and the query compares it with a constant, such as > 0, >= 1, or = 0, " \
                               "so the comparison only asks whether any row matches.",
          "count_distinct_to_subquery" => "A SELECT with a FROM selects only its GROUP BY columns, each written " \
                                          "name.column, and one count(DISTINCT e), with no HAVING, window, or " \
                                          "DISTINCT, and calls no volatile function.",
          "subquery_order_removal" => "A subquery in FROM or a CTE body has an ORDER BY and no LIMIT, OFFSET, or " \
                                      "DISTINCT ON, and every query that reads it either sorts its own rows or only " \
                                      "aggregates them with aggregates, such as count, that ignore their input's " \
                                      "order.",
          "union_to_union_all" => "Each arm of a UNION reads one table and selects every column of a unique, " \
                                  "not-null key of it, and in one position every arm selects a constant tag that " \
                                  "differs from every other arm's, so no two of the UNION's rows can be equal.",
          "coalesce_comparison_split" => "Nothing about the data. The comparison is a condition of a WHERE or an " \
                                         "inner join's ON, which drops a row whether the test is false or NULL.",
          "date_cast_to_range" => "A top-level WHERE or inner-join ON condition compares a timestamp or " \
                                  "timestamptz column, cast to date, with a finite day, using =, <, <=, >, " \
                                  ">=, or BETWEEN.",
          "scalar_aggregates_to_filter" => "Two or more select-list items are uncorrelated scalar subqueries, each " \
                                           "one aggregate over the same one table with no join, GROUP BY, or " \
                                           "LIMIT, in a SELECT with no GROUP BY or bare *, and nothing calls a " \
                                           "volatile function."
        }.freeze
      end
    end
  end
end
