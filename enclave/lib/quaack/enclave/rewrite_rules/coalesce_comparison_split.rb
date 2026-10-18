# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "implied_predicate_removal/columns"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' coalesce_comparison_split. An app that
      # shows a NULL as a default value often filters the same way:
      #
      #   SELECT t.id FROM public.tasks t WHERE COALESCE(t.status, $1) = $2
      #
      # No index on status serves COALESCE(t.status, $1), so Postgres reads
      # every row. This rule writes the same test as
      #
      #   SELECT t.id FROM public.tasks t
      #   WHERE (t.status = $2 OR (t.status IS NULL AND COALESCE($1, t.status) = $2))
      #
      # Once Postgres knows the literals, COALESCE($1, t.status) is just $1,
      # so it folds $1 = $2 to true or false and leaves t.status = $2, or
      # t.status = $2 OR t.status IS NULL. An index serves both. <> splits
      # the same way.
      #
      # Why it's sound, for any literals: when status isn't NULL, both forms
      # compare status with $2. When it's NULL, both compare $1 with $2. The
      # COALESCE keeps its own arguments, only swapped, so it has the
      # original's type and collation. The split's first arm compares the
      # column itself, which uses the same operator only when the COALESCE's
      # type is the column's own, so the rule asks that. The forms differ in
      # one way: when status isn't NULL and $2 is NULL, the original gives
      # NULL and the split gives NULL OR false, which is NULL too, but when
      # status is NULL and $1 = $2 is NULL, the split gives NULL AND NULL. A
      # WHERE or inner-join ON conjunct drops a row that's NULL or false
      # alike, so the rule takes only those positions. It needs no oracle
      # and states no assumption.
      #
      # It fires only when all of this holds, and otherwise gives nothing:
      #
      # - The condition is a top-level conjunct of a SELECT's WHERE, at any
      #   depth, or of an inner join's ON. Not under NOT, OR, IS NULL, or a
      #   LEFT, RIGHT, or FULL join's ON, which keep a row the test fails.
      # - It's a plain = or <> (!= reads as <>), with no schema on the
      #   operator, between COALESCE and a placeholder, either way round.
      #   The placeholder may be cast to any type, which applies alike to
      #   the column and the COALESCE.
      # - The COALESCE has two arguments: a column, then a placeholder used
      #   nowhere else in the query (so nothing else picks its type), cast
      #   to the column's own type, modifiers included, or bare when the
      #   literal oracle says the COALESCE then has the column's type.
      # - The column is written name.column, for a plain table that the
      #   SELECT's FROM names once (Tree.plain_table?, ONLY allowed), or as
      #   a bare name when that FROM is just one plain table that has it.
      class CoalesceComparisonSplit
        include ImpliedPredicateRemoval::Columns

        OPERATORS = %w[= <>].freeze

        # One conjunct the rule can split: the node that holds the
        # condition, the field it's in, the conjunct's index, and the
        # A_Expr, with its COALESCE on the left when left is true.
        Change = Data.define(:holder, :field, :index, :expr, :left)

        def name = "coalesce_comparison_split"

        def description
          "A COALESCE of a column and a placeholder compared with = or <> to a placeholder, in a WHERE or " \
            "inner-join ON, is split into a comparison of the column and a test for its NULLs."
        end

        def rewrites(parse, catalog, literals = nil)
          Array.new(changes(parse.tree, catalog, literals).size) do |i|
            tree = Deparse.copy(parse.tree)
            split!(changes(tree, catalog, literals)[i])
            Rewrite.new(tree:, assumptions: [])
          end
        end

        private

        # Every conjunct the rule can split in tree, a WHERE's before its
        # SELECT's joins, outer SELECTs first.
        def changes(tree, catalog, literals)
          Tree.find_all(tree, PgQuery::SelectStmt).flat_map do |select|
            holders(select).flat_map do |holder, field|
              Tree.conjuncts(holder[field]).each_with_index.filter_map do |condition, index|
                left = side(condition, select, tree, catalog, literals)
                Change.new(holder:, field:, index:, expr: condition.a_expr, left:) unless left.nil?
              end
            end
          end
        end

        def holders(select)
          joins = select.from_clause.flat_map { Tree.joins(it) }.select { it.jointype == :JOIN_INNER && it.quals }
          [[select, "where_clause"], *joins.map { [it, "quals"] }]
        end

        # true when the condition is one the rule can split with its
        # COALESCE on the left, false when on the right, or nil.
        def side(condition, select, tree, catalog, literals)
          expr = condition.a_expr if condition.node == :a_expr
          return unless operator?(expr)

          [true, false].find do |left|
            coalesce, other = left ? [expr.lexpr, expr.rexpr] : [expr.rexpr, expr.lexpr]
            value(other) && splittable?(coalesce, select, tree, catalog, literals)
          end
        end

        # A plain = or <>, not = ANY or IS DISTINCT FROM, whose names are = too.
        def operator?(expr) = expr&.kind == :AEXPR_OP && OPERATORS.include?(operator(expr))

        def splittable?(node, select, tree, catalog, literals)
          return false unless node.node == :coalesce_expr && node.coalesce_expr.args.size == 2

          column, default = node.coalesce_expr.args
          param, cast = value(default)
          info = column.node == :column_ref && own_column_info(column.column_ref, select, catalog)
          return false unless info && param && once?(param.param_ref, tree)

          cast ? own_type?(cast, info, catalog) : resolves_to_column?(param.param_ref, info, literals)
        end

        # Whether COALESCE(column, $n), with $n typed as its literal is,
        # has the column's type. An untyped string takes the column's, but
        # a number may widen it, as 0.5 makes an integer's numeric. Every
        # literal set binds each placeholder with its slow literal's type
        # (LiteralSet), and the default feeds no column predicate, so it
        # keeps its slow value too, and the answer holds in each set.
        def resolves_to_column?(param, info, literals)
          return false unless literals

          null = "NULL::#{info.type}"
          literals.holds?("pg_typeof(COALESCE(#{null}, $#{param.number})) = pg_typeof(#{null})")
        end

        def own_column_info(column, select, catalog)
          table = table(column, select)
          catalog.column_info(table.schemaname, table.relname, column.fields.last.string.sval) if table
        end

        # The plain table the column reads, or nil.
        def table(column, select)
          bare = Tree.bare_name(column)
          table = if bare
                    from = select.from_clause
                    from.first.range_var if from.size == 1 && from.first.node == :range_var
                  else
                    name = Tree.qualified(column)
                    table_for(name.first, select) if name
                  end
          table if table && Tree.plain_table?(table, only: true)
        end

        def once?(param, tree) = Tree.find(tree, PgQuery::ParamRef).one? { it.number == param.number }

        # Puts (column op value OR (column IS NULL AND COALESCE(default,
        # column) op value)) where the change's conjunct was, with each
        # comparison's sides in the original's order.
        def split!(change)
          conjuncts = Tree.conjuncts(change.holder[change.field])
          conjuncts[change.index] = split(change)
          change.holder[change.field] = Tree.all_of(conjuncts)
        end

        def split(change)
          column, default = (change.left ? change.expr.lexpr : change.expr.rexpr).coalesce_expr.args
          swapped = PgQuery::Node.new(coalesce_expr: PgQuery::CoalesceExpr.new(args: [default, column]))
          Tree.any_of([comparison(change, column), Tree.all_of([null_test(column), comparison(change, swapped)])])
        end

        def null_test(column)
          null = Tree.where_of("SELECT WHERE NULL IS NULL")
          null.null_test.arg = Deparse.copy(column)
          null
        end

        # The change's comparison with its COALESCE replaced by node.
        def comparison(change, node)
          expr = Deparse.copy(change.expr)
          change.left ? expr.lexpr = Deparse.copy(node) : expr.rexpr = Deparse.copy(node)
          PgQuery::Node.new(a_expr: expr)
        end
      end
    end
  end
end
