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
                                         "reader can't see the duplicates or the order those clauses change."
        }.freeze
      end
    end
  end
end
