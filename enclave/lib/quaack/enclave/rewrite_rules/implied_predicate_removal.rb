# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "implied_predicate_removal/columns"
require_relative "implied_predicate_removal/containers"
require_relative "implied_predicate_removal/duplicates"
require_relative "implied_predicate_removal/expressions"
require_relative "tree"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' implied_predicate_removal. ORMs often stack scopes
      # that say both `col = $1` and a broader predicate on the same column,
      # such as `col <> $2`, `col IN (...)`, or a range. When Postgres
      # underestimates by multiplying their selectivities, this rule removes
      # the broader predicate that the equality proves.
      class ImpliedPredicateRemoval
        include Expressions
        include Columns
        include Duplicates

        Comparison = Data.define(:condition, :column, :value, :info)

        def name = "implied_predicate_removal"

        def description
          "Redundant predicates in a WHERE or inner-join ON are removed when an equality on the same column " \
            "proves them."
        end

        def rewrites(parse, catalog, literals)
          return [] unless literals

          tree = Deparse.copy(parse.tree)
          changed = false
          each_select(tree) { changed = simplified?(it, catalog, literals) || changed }
          changed ? [Rewrite.new(tree:, assumptions: [])] : []
        end

        private

        # Each SELECT in node, the top level's first, after which its own
        # nested SELECTs: subqueries, CTEs, and set-operation arms. Each is
        # simplified on its own, so an equality only proves what's at its
        # level, and a SELECT inside a dropped conjunct is never reached.
        def each_select(node, &)
          Tree.find(node, PgQuery::SelectStmt).each do |select|
            yield select
            select.class.descriptor.each { each_select(it.get(select), &) }
          end
        end

        def simplified?(select, catalog, literals)
          terms = terms(select)
          return false if terms.empty?

          drop = duplicates(terms, catalog, literals, select)
          drop_implied!(terms, drop, equalities(terms, drop, select, catalog), literals)
          changes_applied?(terms, drop)
        end

        def terms(select)
          containers = inner_join_containers(select.from_clause) + [WhereContainer.new(select)]
          containers.flat_map { terms_for(it) }
        end

        def terms_for(container)
          container.conditions.each_with_index.map { |condition, index| Term.new(container:, index:, condition:) }
        end

        def inner_join_containers(from)
          joins = from.flat_map { Tree.joins(it) }
          return [] unless joins.all? { it.jointype == :JOIN_INNER }

          joins.select { !it.quals.nil? && !it.is_natural && it.using_clause.empty? }.map { OnContainer.new(it) }
        end

        def equalities(terms, drop, select, catalog)
          terms.each_with_index.filter_map do |term, i|
            [i, equality(term.condition, select, catalog)] unless drop.include?(i)
          end.select(&:last)
        end

        def equality(condition, select, catalog)
          expr = condition.a_expr if condition.node == :a_expr
          return unless equality_operator?(expr)

          column, value, cast = comparison_parts(expr)
          info = column_info(column, select, catalog) if column
          return unless info&.deterministic && own_type?(cast, info, catalog)

          Comparison.new(condition:, column:, value:, info:)
        end

        def equality_operator?(expr) = expr&.kind == :AEXPR_OP && operator(expr) == "="

        def comparison_parts(expr)
          column_and_value(expr.lexpr, expr.rexpr) || column_and_value(expr.rexpr, expr.lexpr)
        end

        def implied?(equality, condition, literals)
          return false unless safe?(condition)

          refs = columns(condition)
          return false if refs.empty? || refs.any? { !same_column?(it, equality.column) }

          expr = Deparse.expression(replace_column(condition, equality.column, typed(equality.value, equality.info)))
          literals.holds?(expr)
        rescue Deparse::Error, PgQuery::ParseError
          false
        end

        def drop_implied!(terms, drop, equalities, literals)
          terms.each_with_index do |term, i|
            next if drop.include?(i)

            # A dropped conjunct can't prove another, or two equal equalities would remove each other.
            drop << i if equalities.any? { |j, eq| !drop.include?(j) && proves?(eq, term.condition, literals) }
          end
        end

        def proves?(equality, condition, literals)
          equality.condition != condition && implied?(equality, condition, literals)
        end

        def changes_applied?(terms, drop)
          return false if drop.empty?

          terms.group_by(&:container).each do |container, group|
            remove_from_container(container, group, terms, drop)
          end
          true
        end

        def remove_from_container(container, group, terms, drop)
          removed = group.select { drop.include?(terms.index(it)) }.map(&:index)
          return if removed.empty?

          container.conditions = container.conditions.each_with_index.reject { |_condition, i| removed.include?(i) }
                                          .map(&:first)
        end
      end
    end
  end
end
