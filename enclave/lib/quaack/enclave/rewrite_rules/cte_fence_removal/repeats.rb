# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class CteFenceRemoval
        # Whether a CTE's body runs once in the rewrite, and if not, whether
        # every run gives the same rows.
        #
        # Stored, the body runs once, and every read gets the same rows.
        # Not stored, it runs once per read. A read inside a subquery
        # expression, a LATERAL subquery, or another CTE's body can run once
        # per row of what holds it, or once per read of that CTE. Two runs
        # on one snapshot give the same rows only if they can't depend on
        # the order the body reads rows in, which differs with the plan:
        # each read can push its own conditions into its run, so each run
        # can have its own plan. So a body that runs more than once must
        # have none of these, at any depth:
        #
        # - LIMIT, OFFSET, or FETCH FIRST, which keep whichever rows come
        #   first.
        # - DISTINCT, DISTINCT ON, GROUP BY, or a UNION, INTERSECT, or
        #   EXCEPT without ALL. Each keeps one row of a set it counts as
        #   equal, and two values can be equal but differ, such as 1.0 and
        #   1.00.
        # - An aggregate, window, or set-returning function
        #   (Catalog#row_wise?). array_agg, row_number, and a sum of floats
        #   all depend on the order.
        #
        # The same holds for each CTE the body reads, at any depth, since
        # the body runs it again if Postgres doesn't store it.
        module Repeats
          private

          # Whether the body runs once: the query reads it once, and not
          # from a subquery expression, a LATERAL subquery, or another CTE's
          # body, in the statement the CTE belongs to.
          def once?(entry, reads)
            return false unless reads.size == 1

            read = reads.first
            read.inside.size == entry.inside.size && repeating(entry.owner).none? do |node|
              Tree.find_all(node, PgQuery::RangeVar).any? { it.equal?(read.range_var) }
            end
          end

          def repeating(owner)
            Tree.find_all(owner, PgQuery::SubLink) + Tree.find_all(owner, PgQuery::RangeSubselect).select(&:lateral)
          end

          # Whether every run of the CTE's body, and of each CTE it reads,
          # gives the same rows.
          def same_each_run?(cte, scopes, catalog)
            bodies = read_ctes(cte, scopes).map(&:ctequery)
            bodies.flat_map { Tree.find_all(it, PgQuery::SelectStmt) }.all? { unordered?(it) } &&
              catalog.row_wise?(bodies)
          end

          # The CTE and every CTE its body reads, at any depth, each once.
          def read_ctes(cte, scopes)
            found = [cte]
            found.each do |outer|
              scopes.refs.each do |ref|
                found << ref.target if ref.target && scopes.within?(ref, outer) && found.none? { it.equal?(ref.target) }
              end
            end
            found
          end

          def unordered?(select)
            select.limit_count.nil? && select.limit_offset.nil? && select.distinct_clause.empty? &&
              select.group_clause.empty? && (select.op == :SETOP_NONE || select.all)
          end
        end
      end
    end
  end
end
