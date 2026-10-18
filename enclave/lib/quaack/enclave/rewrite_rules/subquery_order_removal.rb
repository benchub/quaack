# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "subquery_order_removal/blind"
require_relative "subquery_order_removal/targets"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' subquery_order_removal. An app that
      # counts a list's rows may wrap the list's own SQL, ORDER BY and all:
      #
      #   SELECT count(*) FROM
      #     (SELECT posts.* FROM posts WHERE posts.user_id = $1 ORDER BY posts.created_at DESC) subquery_for_count
      #
      # count(*) doesn't look at the order of the rows it counts. But
      # Postgres won't pull a subquery that sorts up into the query that
      # reads it, so it reads every row's created_at from the table and
      # sorts the rows first. Without the ORDER BY, the subquery merges into
      # the count, which can count the entries of an index on user_id:
      #
      #   SELECT count(*) FROM
      #     (SELECT posts.* FROM posts WHERE posts.user_id = $1) subquery_for_count
      #
      # Targets says which SELECTs the rule looks at: each subquery in a
      # FROM, and each CTE body, with the SELECTs that read its rows. It
      # drops the ORDER BY of one when:
      #
      # - It has no LIMIT, OFFSET, or FETCH, which pick rows by their
      #   order, and no DISTINCT ON, which picks one row of each group by
      #   it.
      # - Its select list, ORDER BY, and HAVING call only functions that
      #   give one value per row (Catalog#row_wise?). An aggregate in an
      #   ORDER BY makes a SELECT with no GROUP BY give one row, a window
      #   function can number its rows in that order, and a set-returning
      #   function is left alone with them.
      # - It has a reader, and every reader is blind to the order of its
      #   rows (Blind), with values of types that keep it so (Types).
      # - The statement is a SELECT that calls no volatile function
      #   (Catalog#calls_volatile?). That check refuses anything
      #   SupportedSql doesn't list, too, such as a locking clause, a
      #   data-modifying CTE, or GROUPING SETS.
      #
      # It gives one rewrite per SELECT it can change, each from the
      # original, so the generator's second pass changes two. The IN
      # subqueries and set-operation arms whose ORDER BY
      # subquery_distinct_removal drops are neither subqueries in FROM nor
      # CTE bodies, so the two rules never change the same SELECT. It
      # states no assumption: its rewrite returns the same rows on any data
      # the schema allows, in an order its readers leave as open as before.
      class SubqueryOrderRemoval
        def name = "subquery_order_removal"

        def description
          "A subquery in FROM or a CTE body loses an ORDER BY that has no LIMIT or OFFSET when every query that " \
            "reads it is blind to the order of its rows: it sorts its own output, or it aggregates with only " \
            "aggregates whose result doesn't depend on the order of their input."
        end

        def rewrites(parse, catalog, literals = nil)
          chosen(parse.tree, catalog, literals).map do |i|
            tree = Deparse.copy(parse.tree)
            Targets.in(tree)[i].select.sort_clause.clear
            Rewrite.new(tree:, assumptions: [])
          end
        end

        private

        # The indices, in Targets.in(tree), of the SELECTs whose ORDER BY
        # the rule drops.
        def chosen(tree, catalog, literals)
          targets = Targets.in(tree)
          chosen = targets.each_index.select { removable?(targets[it], tree, catalog, literals) }
          chosen.any? && !volatile?(tree, catalog) ? chosen : []
        end

        def removable?(target, tree, catalog, literals)
          select = target.select
          select.sort_clause.any? && unlimited?(select) && one_per_row?(select, catalog) && target.readers.any? &&
            target.readers.all? { Blind.reader?(it, tree, catalog, literals) }
        end

        # Whether select has no LIMIT, OFFSET, or DISTINCT ON.
        def unlimited?(select)
          select.limit_count.nil? && select.limit_offset.nil? && select.distinct_clause.all? { it.node.nil? }
        end

        def one_per_row?(select, catalog)
          catalog.row_wise?([*select.target_list, *select.sort_clause.map { it.sort_by.node }, select.having_clause]
                              .compact)
        end

        def volatile?(tree, catalog)
          catalog.calls_volatile?(Deparse.faithfully(tree))
        rescue Deparse::Error
          true
        end
      end
    end
  end
end
