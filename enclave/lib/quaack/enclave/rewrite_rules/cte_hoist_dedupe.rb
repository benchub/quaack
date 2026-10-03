# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "../redaction"
require_relative "cte_hoist_dedupe/scopes"
require_relative "implied_predicate_removal/expressions"
require_relative "tree"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md 6c's cte_hoist_dedupe. Postgres runs each CTE on its own,
      # so the same CTE written in every arm of a UNION, and again in the
      # outer WHERE, runs once per copy:
      #
      #   SELECT ... WHERE users.id IN (WITH uia AS MATERIALIZED (SELECT user_id FROM uaa WHERE account_id = $1)
      #                                 SELECT user_id FROM uia) ...
      #
      # This finds CTEs at any depth whose bodies, column names, and
      # materialization option match, with the literal oracle deciding
      # whether two placeholders match. It defines one copy, the first in
      # the tree, at the front of the top-level WITH, takes the others out
      # of their WITHs (and drops a WITH left empty), and points every
      # reference to a copy at it. It fires only when two copies merge.
      #
      # Why that's sound. Every copy reads the same snapshot, so a copy that
      # calls no volatile function gives the same rows wherever it runs,
      # provided every name in it means the same at the top. So a copy
      # merges only when:
      #
      # - Postgres can analyze its body alone (Catalog#self_contained?), so
      #   no column or table alias in it comes from outside it, and each
      #   name it resolves inside resolves the same anywhere, since a
      #   nearer scope wins.
      # - No unqualified table name in it reads a CTE outside its body.
      #   Another unqualified name is a table, as it is at the front of a
      #   WITH that isn't RECURSIVE.
      # - It calls no volatile function (Catalog#calls_volatile?).
      # - Its WITH isn't RECURSIVE. Nor may the top-level WITH be, and no
      #   CTE in the query may modify data.
      #
      # The hoisted CTE keeps the first copy's name unless another CTE has
      # it, or an unqualified table name that isn't a copy's reference
      # does. Then it's quaack_cte_<n>, the first such name the query
      # doesn't use. Either way no CTE can hide it at any reference. A
      # renamed reference keeps its old name as an alias, so the columns
      # qualified by it still read it.
      #
      # A copy inside another copy's body goes with that body: only the
      # outer one merges. It states no assumptions.
      class CteHoistDedupe
        include ImpliedPredicateRemoval::Expressions

        BASE = "quaack_cte"

        def name = "cte_hoist_dedupe"

        def description
          "CTEs with the same body, at any depth, become one CTE in the top-level WITH that every reference reads."
        end

        def rewrites(parse, catalog, literals)
          return [] unless literals

          tree = Deparse.copy(parse.tree)
          top = Tree.select(tree)
          return [] if top.nil? || top.with_clause&.recursive || Redaction.writes?(tree)

          scopes = Scopes.new(top)
          groups = merging(scopes, catalog, literals)
          return [] if groups.empty?

          hoist!(top, groups, scopes, taken(tree))
          [Rewrite.new(tree:, assumptions: [])]
        end

        private

        # The groups of copies to merge, each in tree order.
        def merging(scopes, catalog, literals)
          eligible = scopes.ctes.select { hoistable?(it, scopes, catalog) }
          paired = eligible.select { |entry| eligible.any? { !it.equal?(entry) && same_cte?(it, entry, literals) } }
          outermost = paired.reject { |entry| paired.any? { scopes.within?(entry, it.cte) } }
          groups(outermost, literals).select { it.size > 1 }
        end

        def groups(entries, literals)
          entries.each_with_object([]) do |entry, groups|
            group = groups.find { same_cte?(it.first, entry, literals) }
            group ? group << entry : groups << [entry]
          end
        end

        def same_cte?(one, other, literals) = same_expression?(unnamed(one.cte), unnamed(other.cte), literals)

        def unnamed(cte) = Deparse.copy(cte).tap { it.ctename = "" }

        def hoistable?(entry, scopes, catalog)
          return false if entry.with_clause.recursive || reads_outer_cte?(entry, scopes)

          sql = Deparse.statement(entry.cte.ctequery.select_stmt)
          catalog.self_contained?(sql) && !catalog.calls_volatile?(sql)
        rescue Deparse::Error
          false
        end

        def reads_outer_cte?(entry, scopes)
          scopes.refs.any? do |ref|
            scopes.within?(ref, entry.cte) && ref.target && !scopes.within?(scopes.entry(ref.target), entry.cte)
          end
        end

        def hoist!(top, groups, scopes, taken)
          hoisted = groups.map { hoisted(it, scopes, taken) }
          top.with_clause ||= PgQuery::WithClause.new
          hoisted.reverse_each { top.with_clause.ctes.unshift(it) }
        end

        # Points every reference to the group's copies at one CTE, takes
        # the copies out, and gives that CTE's node.
        def hoisted(group, scopes, taken)
          name = keep?(group, scopes) ? group.first.cte.ctename : fresh(taken)
          cte = Deparse.copy(group.first.cte).tap { it.ctename = name }
          redirect_all(group, scopes, name)
          group.each { remove(it) }
          PgQuery::Node.new(common_table_expr: cte)
        end

        def redirect_all(group, scopes, name)
          scopes.refs.each { redirect(it.range_var, name) if member?(group, it.target) }
        end

        def member?(group, cte) = group.any? { it.cte.equal?(cte) }

        def keep?(group, scopes)
          name = group.first.cte.ctename
          scopes.ctes.all? { it.cte.ctename != name || member?(group, it.cte) } &&
            scopes.refs.all? { it.range_var.relname != name || member?(group, it.target) }
        end

        def redirect(range_var, name)
          return if range_var.relname == name

          range_var.alias ||= PgQuery::Alias.new(aliasname: range_var.relname)
          range_var.relname = name
        end

        def remove(entry)
          entry.with_clause.ctes.delete_if { it.common_table_expr.equal?(entry.cte) }
          entry.owner.with_clause = nil if entry.with_clause.ctes.empty?
        end

        def fresh(taken) = (1..).lazy.map { "#{BASE}_#{it}" }.find { taken.add?(it) }

        # Every name the query uses: CTEs', tables', aliases', and every
        # other identifier.
        def taken(tree)
          [[PgQuery::CommonTableExpr, :ctename], [PgQuery::RangeVar, :relname], [PgQuery::Alias, :aliasname],
           [PgQuery::String, :sval]].flat_map { |type, field| Tree.find(tree, type).map(&field) }.to_set
        end
      end
    end
  end
end
