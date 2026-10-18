# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "../redaction"
require_relative "cte_fence_removal/pushdown"
require_relative "cte_fence_removal/repeats"
require_relative "cte_hoist_dedupe/scopes"
require_relative "tree"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' cte_fence_removal. Postgres runs a CTE on
      # its own, and stores its rows, when it's written AS MATERIALIZED or
      # the query reads it more than once. Then no condition of a reader
      # reaches the body, and the body can't use an index for it:
      #
      #   WITH recent AS MATERIALIZED (SELECT id, customer_id FROM public.orders WHERE created_at >= $1)
      #   SELECT id FROM recent WHERE customer_id = $2
      #
      # This writes the CTE AS NOT MATERIALIZED, and changes nothing else:
      #
      #   WITH recent AS NOT MATERIALIZED (SELECT id, customer_id FROM public.orders WHERE created_at >= $1)
      #   SELECT id FROM recent WHERE customer_id = $2
      #
      # Postgres then plans the body as a subquery in each place the query
      # reads it, and can push each reader's conditions into it. It gives
      # one rewrite per CTE it can change, at any depth, each changing only
      # that CTE. A CTE Postgres doesn't store gets none: one that's
      # already NOT MATERIALIZED, a plain one the query reads once, which
      # Postgres already plans that way, and one the query never reads.
      #
      # Why that's sound. Every read sees the same snapshot, so a body that
      # calls no volatile function (Catalog#calls_volatile?), modifies no
      # data, and doesn't recurse gives the same rows as a subquery as it
      # does stored. A body read once becomes a subquery in that one place,
      # as if the query had been written that way. A body read more than
      # once runs once per read, and from inside a subquery expression, a
      # LATERAL subquery, or another CTE's body, it can run once per row
      # there. Each run must then give the same rows, so Repeats refuses a
      # body whose rows can depend on the order it reads rows in. So the
      # rule refuses:
      #
      # - A query with a RECURSIVE WITH, or a data-modifying CTE, anywhere.
      # - A body that calls a volatile function.
      # - A CTE whose name starts with quaack_, such as shared_scan_cte's,
      #   which this would undo.
      # - A body that runs more than once and can give each run other rows
      #   (see Repeats).
      # - A query with a condition that, inlined, Postgres could run on a
      #   row the body drops, and that can raise there (see Pushdown).
      #
      # It states no assumptions.
      class CteFenceRemoval
        include Pushdown
        include Repeats

        PREFIX = "quaack_"

        def name = "cte_fence_removal"

        def description
          "A CTE written AS MATERIALIZED, or one the query reads more than once, becomes AS NOT MATERIALIZED, so " \
            "the planner can push each reader's conditions into it."
        end

        def rewrites(parse, catalog, _literals = nil)
          top = Tree.select(parse.tree)
          return [] if top.nil? || Redaction.writes?(parse.tree) ||
                       Tree.find_all(parse.tree, PgQuery::WithClause).any?(&:recursive)

          CteHoistDedupe::Scopes.new(top).ctes.each_index.filter_map { rewrite(parse.tree, it, catalog) }
        end

        private

        def rewrite(original, index, catalog)
          tree = Deparse.copy(original)
          top = Tree.select(tree)
          scopes = CteHoistDedupe::Scopes.new(top)
          entry = scopes.ctes[index]
          return unless removable?(top, entry, scopes, catalog)

          entry.cte.ctematerialized = :CTEMaterializeNever
          Rewrite.new(tree:, assumptions: [])
        end

        def removable?(top, entry, scopes, catalog)
          cte = entry.cte
          reads = scopes.refs.select { it.target.equal?(cte) }
          stored?(cte, reads) && eligible?(cte, catalog) &&
            (once?(entry, reads) || same_each_run?(cte, scopes, catalog)) && !raises?(top, cte, catalog)
        end

        # Whether Postgres stores the CTE's rows: it's MATERIALIZED and the
        # query reads it, or it's plain and the query reads it more than once.
        def stored?(cte, reads)
          case cte.ctematerialized
          when :CTEMaterializeAlways then reads.any?
          when :CTEMaterializeDefault then reads.size > 1
          else false
          end
        end

        # Whether the CTE isn't another rule's, and calls no volatile function.
        def eligible?(cte, catalog) = !cte.ctename.start_with?(PREFIX) && !volatile?(cte, catalog)

        def volatile?(cte, catalog)
          catalog.calls_volatile?(Deparse.statement(cte.ctequery.select_stmt))
        rescue Deparse::Error
          true
        end
      end
    end
  end
end
