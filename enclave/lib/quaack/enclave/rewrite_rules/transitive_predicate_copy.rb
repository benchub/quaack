# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "implied_predicate_removal/containers"
require_relative "implied_predicate_removal/expressions"
require_relative "tree"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md 6c's transitive_predicate_copy. Postgres carries a
      # constant equality across an equi-join, but not an IN list, a range,
      # or BETWEEN. So for each equality a.x = b.y in a top-level AND of a
      # WHERE or an inner join's ON, this copies such a filter on a.x to
      # b.y, in the same WHERE or ON as the filter, with the same
      # placeholders. Any row that passes has a.x = b.y, so b.y passes
      # whatever a.x passes.
      class TransitivePredicateCopy
        include ImpliedPredicateRemoval::Expressions

        RANGES = %w[< <= > >=].freeze

        # Where a conjunct sits, and the names of the tables it can read, or
        # nil for a WHERE, which can read them all.
        Place = Data.define(:container, :names)
        # Each side a column's Node.
        Equality = Data.define(:left, :right)

        def name = "transitive_predicate_copy"

        def description
          "A filter on one side of a column equality in a WHERE or inner-join ON is copied to the other side."
        end

        def rewrites(parse, catalog, literals)
          return [] unless literals

          tree = Deparse.copy(parse.tree)
          changed = selects(tree).map { copied?(it, catalog, literals) }.any?
          changed ? [Rewrite.new(tree:, assumptions: [])] : []
        end

        private

        # Every SELECT in node, those inside another's included, outermost
        # first.
        def selects(node)
          Tree.find(node, PgQuery::SelectStmt).flat_map do |select|
            [select, *select.class.descriptor.flat_map { selects(it.get(select)) }]
          end
        end

        def copied?(select, catalog, literals)
          places = places(select)
          equalities = places.flat_map do |place|
            place.container.conditions.filter_map { equality(it, select, catalog) }
          end
          return false if equalities.empty?

          places.map { copied_into?(it, places, equalities, literals) }.any?
        end

        def places(select)
          joins = select.from_clause.flat_map { Tree.joins(it) }.select { inner_on?(it) }
          ons = joins.map do |join|
            names = Tree.from_items([join.larg, join.rarg]).map(&:name)
            Place.new(container: ImpliedPredicateRemoval::OnContainer.new(join), names:)
          end
          ons + [Place.new(container: ImpliedPredicateRemoval::WhereContainer.new(select), names: nil)]
        end

        def inner_on?(join) = join.jointype == :JOIN_INNER && !join.quals.nil?

        # Adds every copy the place's conjuncts lead to, the copies' own
        # included, since each walks past the end as copies are added. So a
        # chain of equalities carries a filter all along it.
        def copied_into?(place, places, equalities, literals)
          conditions = place.container.conditions
          others = places.reject { it.equal?(place) }.flat_map { it.container.conditions }
          before = conditions.size
          conditions.each { |condition| add_copies(condition, place, equalities, conditions, others, literals) }
          return false if conditions.size == before

          place.container.conditions = conditions
          true
        end

        # Appends to conditions each copy of condition across an equality
        # that the place can read and that isn't already there.
        def add_copies(condition, place, equalities, conditions, others, literals) # rubocop:disable Metrics/ParameterLists
          column = filtered_column(condition)
          return unless column

          equalities.each do |equality|
            target = other(equality, column)
            next unless target && visible?(target.column_ref, place)

            copy = replace_column(condition, column, target)
            conditions << copy unless (conditions + others).any? { same_expression?(it, copy, literals) }
          end
        end

        def other(equality, column)
          return equality.right if same_column?(equality.left.column_ref, column)

          equality.left if same_column?(equality.right.column_ref, column)
        end

        def visible?(column, place) = place.names.nil? || place.names.include?(Tree.qualified(column).first)

        # The column that condition filters with an IN list of constants, a
        # comparison with a constant, or BETWEEN two constants, or nil. A
        # constant is a bare placeholder: a cast or a COLLATE could make it
        # mean something else for another column.
        def filtered_column(condition)
          return unless condition.node == :a_expr

          expr = condition.a_expr
          case expr.kind
          when :AEXPR_IN then list_column(expr) if operator(expr) == "="
          when :AEXPR_BETWEEN then list_column(expr)
          when :AEXPR_OP then range_column(expr) if RANGES.include?(operator(expr))
          end
        end

        def list_column(expr)
          expr.lexpr.column_ref if expr.lexpr.node == :column_ref && expr.rexpr.list.items.all? { constant?(it) }
        end

        def range_column(expr)
          return expr.lexpr.column_ref if expr.lexpr.node == :column_ref && constant?(expr.rexpr)

          expr.rexpr.column_ref if expr.rexpr.node == :column_ref && constant?(expr.lexpr)
        end

        def constant?(node) = node.node == :param_ref

        def operator(expr)
          expr.name.map { it.string.sval }.join(".") if expr.name.all? { it.node == :string }
        end

        # a.x = b.y, where both are columns of plain tables in this SELECT's
        # FROM, not on an outer join's nullable side, of one type and one
        # deterministic collation, whose comparisons are its default btree's.
        def equality(condition, select, catalog)
          expr = condition.a_expr if condition.node == :a_expr
          return unless expr&.kind == :AEXPR_OP && operator(expr) == "="
          return unless [expr.lexpr, expr.rexpr].all? { it.node == :column_ref }

          Equality.new(left: expr.lexpr, right: expr.rexpr) if comparable?(expr, select, catalog)
        end

        def comparable?(expr, select, catalog)
          left, right = [expr.lexpr, expr.rexpr].map { column_facts(it.column_ref, select, catalog) }
          left && left == right && left.first.deterministic && left.last
        end

        # The column's Catalog::Info and whether its type's comparisons are
        # its default btree's, or nil for a column this can't place.
        def column_facts(column, select, catalog)
          qualifier, name = Tree.qualified(column)
          table = Tree.plain_table_named(select.from_clause, qualifier) if name
          return unless table

          info = catalog.column_info(table.schemaname, table.relname, name)
          [info, catalog.default_btree?(table.schemaname, table.relname, name)] if info
        end
      end
    end
  end
end
