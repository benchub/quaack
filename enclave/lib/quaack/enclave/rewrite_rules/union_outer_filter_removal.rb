# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "implied_predicate_removal/expressions"
require_relative "tree"
require_relative "union_outer_filter_removal/conjuncts"
require_relative "union_outer_filter_removal/union"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md 6c's union_outer_filter_removal. An ORM that builds a
      # search as a UNION of arms often filters the UNION's result with the
      # same conjuncts every arm already has:
      #
      #   SELECT users.* FROM (SELECT users.* FROM public.users WHERE ... AND users.workflow_state <> $1
      #                        UNION SELECT users.* FROM public.users WHERE ... AND users.workflow_state <> $2) users
      #   WHERE users.workflow_state <> $3
      #
      # The outer copy can't drop a row, but Postgres still runs it. This
      # drops a top-level WHERE conjunct whose columns, outside its
      # subqueries, are all one UNION subquery's, when every arm's
      # top-level WHERE has the same conjunct on the columns the arm outputs
      # in those positions. The literal oracle decides whether two
      # placeholders match.
      #
      # Why that's sound. Every row an arm outputs passed its WHERE, and so
      # its conjunct, on the values it outputs. GROUP BY, DISTINCT ON,
      # ORDER BY, and LIMIT only choose among those rows, and UNION keeps
      # one of each set of equal rows. So the outer conjunct, evaluated on
      # the same values, passes every row the UNION gives, provided it
      # means the same in both places. It does when:
      #
      # - Each column it reads is a plain table's column in every arm, of
      #   one type and collation, so UNION casts no value.
      # - Postgres can analyze each of its subqueries alone under the
      #   top-level WITH, so every name in one resolves inside it or to
      #   that WITH, and no WITH nearer an arm defines a CTE it names.
      # - It calls no volatile function (Catalog#calls_volatile?).
      # - The UNION isn't LATERAL, on an outer join's nullable side, or
      #   grouped by grouping sets in any arm. Its set operations are all
      #   UNION or UNION ALL.
      #
      # It states no assumptions.
      class UnionOuterFilterRemoval
        include ImpliedPredicateRemoval::Expressions

        def name = "union_outer_filter_removal"

        def description
          "A WHERE conjunct on a UNION subquery's columns is removed when every arm's WHERE already applies it to " \
            "the column it outputs."
        end

        def rewrites(parse, catalog, literals)
          return [] unless literals

          tree = Deparse.copy(parse.tree)
          top = Tree.select(tree)
          return [] unless top&.op == :SETOP_NONE

          unions = Union.all(top, catalog)
          conditions = Tree.conjuncts(top.where_clause)
          kept = conditions.reject { implied?(it, unions, top, catalog, literals) }
          return [] if kept.size == conditions.size

          top.where_clause = Tree.all_of(kept)
          [Rewrite.new(tree:, assumptions: [])]
        end

        private

        def implied?(condition, unions, top, catalog, literals)
          union = union_of(condition, unions)
          return false unless union && stands?(condition, top, catalog)

          union.arms.all? { applies?(it, union, condition, literals) }
        end

        # The Union whose columns, each in one position, are all the
        # condition's outside its subqueries, or nil.
        def union_of(condition, unions)
          names = Conjuncts.columns(condition).map { Tree.qualified(it) }
          qualifier = qualifier(names)
          union = unions[qualifier] if qualifier
          union if union && names.all? { union.position(it.last) }
        end

        # The one qualifier of names, when there are some, and each is
        # written as name.column.
        def qualifier(names)
          qualifiers = names.map { it&.first }.uniq
          qualifiers.first if !names.empty? && !names.include?(nil) && qualifiers.size == 1
        end

        def stands?(condition, top, catalog)
          return false if catalog.calls_volatile?(Deparse.statement(Conjuncts.filter(condition)))

          Conjuncts.sublinks(condition).all? do |sublink|
            catalog.self_contained?(Deparse.statement(Conjuncts.standalone(sublink, top)))
          end
        rescue Deparse::Error
          false
        end

        # Whether the arm's WHERE has the condition, with each of the
        # UNION's columns replaced by the column the arm outputs there.
        def applies?(arm, union, condition, literals)
          return false if hides?(arm, condition)

          expected = Conjuncts.map_columns(Deparse.copy(condition)) do |ref|
            Deparse.copy(arm.outputs[union.position(Tree.qualified(ref).last)].column)
          end
          Tree.conjuncts(arm.select.where_clause).any? { same_expression?(it, expected, literals) }
        end

        def hides?(arm, condition)
          tables = Conjuncts.sublinks(condition).flat_map { Tree.find(it.subselect, PgQuery::RangeVar) }
          tables.any? { it.schemaname.empty? && arm.hidden.include?(it.relname) }
        end
      end
    end
  end
end
