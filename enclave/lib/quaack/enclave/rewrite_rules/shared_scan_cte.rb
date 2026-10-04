# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "implied_predicate_removal/containers"
require_relative "implied_predicate_removal/expressions"
require_relative "shared_scan_cte/copies"
require_relative "tree"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md 6c's shared_scan_cte. A query that reads one table twice,
      # each copy filtered the same way, scans it twice:
      #
      #   SELECT ... FROM public.submissions JOIN public.submissions AS assessor_asset ON ...
      #   WHERE submissions.course_id IN ($1, $2) AND assessor_asset.course_id IN ($3, $4) AND ...
      #
      # This reads it once, in a MATERIALIZED CTE of the conjuncts every
      # copy shares, which each copy then reads under its old alias:
      #
      #   WITH quaack_scan_of_submissions AS MATERIALIZED
      #     (SELECT * FROM public.submissions WHERE submissions.course_id IN ($1, $2))
      #   SELECT ... FROM quaack_scan_of_submissions submissions
      #   JOIN quaack_scan_of_submissions assessor_asset ON ... WHERE ...
      #
      # A copy's conjuncts are the top-level conjuncts of the WHERE and of
      # each inner join's ON that read only its own columns, qualified by
      # its alias, with no subquery. Two copies share a conjunct when it's
      # the same with each one's alias in place of the other's, the literal
      # oracle deciding whether two placeholders match. Shared conjuncts
      # leave every copy and go in the CTE, with the first copy's
      # placeholders. Every other conjunct stays where it was. An ON left
      # with nothing becomes ON true.
      #
      # Why that's sound. Every copy reads the same snapshot, and the CTE
      # calls no volatile function, so it holds exactly the rows of the
      # table that pass the shared conjuncts, and each copy reads those
      # rows. A copy on no outer join's nullable side gets the same rows
      # whether a conjunct of its own filters its scan, the join's ON, or
      # the WHERE. SELECT * gives the CTE the table's columns, by name and
      # type, so every reference to a copy's column reads the same value.
      #
      # It works only on the top-level FROM, where every FROM item must
      # have a name (a set operation has none), and only on plain tables
      # (see Tree.plain_table?): a copy elsewhere is left alone. It refuses
      # a table with a copy on an outer join's nullable side, and a query
      # that already has a CTE of the name, at any depth. A name longer
      # than Postgres keeps, which it would cut short, fails
      # Deparse.faithfully. A locking clause and a data-modifying CTE
      # never get here: SupportedSql refuses them. A
      # CTE's row type isn't the table's, so it refuses a query that reads
      # a copy's whole row, other than as a copy.* in the select list. Last,
      # Postgres must be able to prepare the rewrite. It can't when the
      # query names a copy's system column, such as ctid, or a column as
      # schema.table.column, or when GROUP BY relied on the table's primary
      # key. It states no assumptions.
      class SharedScanCte
        include ImpliedPredicateRemoval::Expressions
        include Copies

        PREFIX = "quaack_scan_of_"
        # Each copy's alias becomes this when its conjuncts are compared.
        COPY = "quaack_copy"
        TEMPLATE = "WITH quaack AS MATERIALIZED (SELECT * FROM quaack) SELECT"
        WherePlace = ImpliedPredicateRemoval::WhereContainer
        OnPlace = ImpliedPredicateRemoval::OnContainer

        def name = "shared_scan_cte"

        def description
          "A table read more than once in the top-level FROM is read once, by a MATERIALIZED CTE of the WHERE and " \
            "inner-join ON conjuncts every copy shares."
        end

        def rewrites(parse, catalog, literals)
          top = Tree.select(parse.tree)
          return [] unless literals && top

          tables(top).filter_map { rewrite(parse.tree, it, catalog, literals) }
        end

        private

        def rewrite(original, table, catalog, literals)
          tree = Deparse.copy(original)
          top = Tree.select(tree)
          copies, shared = shareable(tree, top, table, literals)
          return unless shared&.any?

          cte = cte(PREFIX + table.last, copies.first.table, shared)
          return if volatile?(catalog, cte)

          share!(top, copies, shared, cte, literals)
          Rewrite.new(tree:, assumptions: []) if catalog.self_contained?(Deparse.faithfully(tree))
        rescue Deparse::Error
          nil
        end

        def volatile?(catalog, cte) = catalog.calls_volatile?(Deparse.statement(cte.ctequery.select_stmt))

        # The table's copies, and the conjuncts they share, unless it
        # refuses them.
        def shareable(tree, top, table, literals)
          copies = items(top).select { copy?(it) && key(it.table) == table }
          return if copies.any?(&:nullable) || taken?(tree, PREFIX + table.last) ||
                    whole_row?(tree, top, copies.map(&:name))

          [copies, shared(copies, places(top), literals)]
        end

        # The WHERE and each inner join's ON.
        def places(top)
          joins = top.from_clause.flat_map { Tree.joins(it) }.select { it.jointype == :JOIN_INNER && it.quals }
          [WherePlace.new(top), *joins.map { OnPlace.new(it) }]
        end

        # The first copy's conjuncts that every other copy has too, each
        # once, under COPY.
        def shared(copies, places, literals)
          conditions = places.flat_map(&:conditions)
          first, *rest = copies.map { |copy| own(conditions, copy.name) }
          first.each_with_object([]) do |condition, shared|
            next if has?(shared, condition, literals)

            shared << condition if rest.all? { has?(it, condition, literals) }
          end
        end

        def own(conditions, name) = conditions.select { reads_only?(it, name) }.map { requalified(it, COPY) }

        def reads_only?(condition, name)
          refs = Tree.find(condition, PgQuery::ColumnRef)
          refs.any? && refs.all? { Tree.qualified(it)&.first == name } && Tree.find(condition, PgQuery::SubLink).empty?
        end

        def requalified(condition, qualifier)
          Deparse.copy(condition).tap { |copy| Tree.find(copy, PgQuery::ColumnRef).each { Tree.qualify!(it, qualifier) } }
        end

        def has?(conditions, condition, literals) = conditions.any? { same_expression?(it, condition, literals) }

        def cte(name, table, shared)
          cte = PgQuery.parse(TEMPLATE).tree.stmts.first.stmt.select_stmt.with_clause.ctes.first.common_table_expr
          cte.ctename = name
          fill!(cte.ctequery.select_stmt, table, shared)
          cte
        end

        def fill!(body, table, shared)
          body.from_clause[0] = PgQuery::Node.new(range_var: Deparse.copy(table).tap { it.alias = nil })
          body.where_clause = Tree.all_of(shared.map { requalified(it, table.relname) })
        end

        # Takes the shared conjuncts out of every place, points each copy
        # at the CTE, and puts the CTE first in the top-level WITH.
        def share!(top, copies, shared, cte, literals)
          places(top).each { strip!(it, copies, shared, literals) }
          copies.each { point(it.table, cte.ctename) }
          top.with_clause ||= PgQuery::WithClause.new
          top.with_clause.ctes.unshift(PgQuery::Node.new(common_table_expr: cte))
        end

        def strip!(place, copies, shared, literals)
          kept = place.conditions.reject { |condition| shared?(condition, copies, shared, literals) }
          place.conditions = kept.empty? && place.is_a?(OnPlace) ? [Tree.true_const] : kept
        end

        def shared?(condition, copies, shared, literals)
          copies.any? { reads_only?(condition, it.name) } && has?(shared, requalified(condition, COPY), literals)
        end

        def point(range, name)
          range.alias ||= PgQuery::Alias.new(aliasname: range.relname)
          range.schemaname = ""
          range.relname = name
        end
      end
    end
  end
end
