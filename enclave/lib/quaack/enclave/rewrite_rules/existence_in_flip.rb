# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "tree"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md 6c's existence_in_flip. An existence check, such as
      # Rails's exists?, with an IN subquery
      #
      #   SELECT $1 AS one FROM enrollments JOIN ... WHERE enrollments.user_id = $2 AND ...
      #     AND assignments.id IN (SELECT lookups.assignment_id FROM lookups WHERE lookups.code = $3) LIMIT $4
      #
      # lets Postgres bet on a fast-start plan from the outer tables, which
      # loses when few of their rows match. This turns it inside out, so
      # the subquery's table drives:
      #
      #   SELECT $1 AS one FROM lookups WHERE lookups.code = $3 AND EXISTS (SELECT 1 FROM enrollments
      #     JOIN ... WHERE enrollments.user_id = $2 AND ... AND assignments.id = lookups.assignment_id) LIMIT $4
      #
      # Why that's sound. Each returns a row exactly when some row of the
      # subquery's FROM passes its WHERE and some row of the original's
      # FROM passes the other conjuncts with x = y true. IN is true exactly
      # when = is, with the same operator, so NULLs match nothing in both.
      # The select list is all placeholders and the limit is 1, so that row
      # is the same row. Names resolve as they did. The top-level WITH
      # stays at the top. The original's FROM is still nearer than the
      # subquery's to every name it read. The subquery's FROM and WHERE
      # move to the top level, where nothing else is in scope, so a name in
      # them that read the outer query no longer resolves, and Postgres
      # refuses to prepare the rewrite. That's how a correlated subquery is
      # refused. Only y moves to where the original's FROM could capture
      # it, so it's qualified, and its table renamed if the original's FROM
      # has its name.
      #
      # It fires only when all of this holds:
      #
      # - The query is one SELECT whose select list is all placeholders,
      #   with LIMIT a placeholder the literal oracle says is 1, and no
      #   DISTINCT, GROUP BY, HAVING, WINDOW, ORDER BY, or OFFSET.
      #   Aggregates and window functions can then appear nowhere at its
      #   level. It calls no volatile function anywhere. A locking clause
      #   never gets here: SupportedSql refuses it.
      # - The IN is one of the conditions its WHERE ANDs together, written
      #   x IN (SELECT y ...), not = ANY. SupportedSql refuses a row as x.
      # - The subquery is one plain SELECT of one column (see
      #   Tree.plain_select?), so no set operation, LIMIT, OFFSET, GROUP BY,
      #   HAVING, DISTINCT ON, or WITH, and no aggregate. A plain DISTINCT
      #   is dropped, since IN doesn't count rows. y is written
      #   name.column, or just column when the subquery's FROM is one
      #   table, which then qualifies it.
      # - Every top-level item of the original's FROM has a name Tree can
      #   read. If one has y's qualifier, that is a table of the subquery's
      #   FROM, which has no subquery of its own, so every reference to it
      #   can be renamed.
      # - Postgres can prepare the rewrite.
      #
      # It gives one rewrite per IN that qualifies, and states no
      # assumptions.
      class ExistenceInFlip
        def name = "existence_in_flip"

        def description
          "An existence check under LIMIT 1 is turned inside out: an uncorrelated IN subquery's table drives, and " \
            "the rest of the query becomes an EXISTS correlated on the IN's two sides."
        end

        def rewrites(parse, catalog, literals)
          top = Tree.select(parse.tree)
          return [] unless literals && top && existence_check?(top, literals)
          return [] if catalog.calls_volatile?(Deparse.faithfully(parse.tree))

          Array.new(Tree.conjuncts(top.where_clause).size) { rewrite(parse.tree, it, catalog) }.compact
        rescue Deparse::Error
          []
        end

        private

        def existence_check?(top, literals)
          top.target_list.all? { it.res_target.val.node == :param_ref } && plain_level?(top) &&
            one?(top.limit_count, literals)
        end

        # Whether nothing at the query's level groups, orders, or skips rows.
        def plain_level?(top)
          top.distinct_clause.empty? && top.group_clause.empty? && top.having_clause.nil? &&
            top.window_clause.empty? && top.sort_clause.empty? && top.limit_offset.nil?
        end

        def one?(limit, literals) = limit&.node == :param_ref && literals.holds?("$#{limit.param_ref.number} = 1")

        # A copy of the tree flipped on the WHERE's index-th condition, or
        # nil if this rule doesn't apply to it.
        def rewrite(original, index, catalog)
          tree = flipped(Deparse.copy(original), index)
          Rewrite.new(tree:, assumptions: []) if tree && catalog.self_contained?(Deparse.faithfully(tree))
        rescue Deparse::Error
          nil
        end

        # The tree, flipped in place, or nil.
        def flipped(tree, index)
          top = Tree.select(tree)
          conditions = Tree.conjuncts(top.where_clause)
          link = in_link(conditions[index])
          column = link && selected(link.subselect.select_stmt, top.from_clause, tree)
          return unless column

          flip!(top, conditions.reject.with_index { |_, i| i == index }, link, column)
          tree
        end

        # The SubLink of a condition that is x IN (SELECT y ...), or nil.
        def in_link(condition)
          link = condition.sub_link if condition.node == :sub_link
          return unless link&.sub_link_type == :ANY_SUBLINK && link.oper_name.empty?

          link if link.subselect.node == :select_stmt && one_column?(link.subselect.select_stmt)
        end

        # Whether the subquery is one plain SELECT of one column.
        def one_column?(sub)
          Tree.plain_select?(sub) && sub.target_list.size == 1 &&
            sub.target_list.first.res_target.val.node == :column_ref
        end

        # The subquery's selected column, qualified, with its table renamed
        # if the original's FROM has its name, or nil if it can't be.
        def selected(sub, from, tree)
          column = qualify!(sub.target_list.first.res_target.val.column_ref, sub)
          names = Tree.from_items(from).map(&:name)
          return unless column && !names.include?(nil)

          name = Tree.qualified(column).first
          column if !names.include?(name) || rename!(sub, name, tree)
        end

        # The column as name.column, or nil: it was, or it was a bare column
        # of the subquery's one table.
        def qualify!(column, sub)
          fields = column.fields
          return unless fields.all? { it.node == :string } && fields.size.between?(1, 2)
          return column if fields.size == 2

          return unless (table = sole_table(sub))

          fields.unshift(string(Tree.refname(table)))
          column
        end

        def sole_table(sub)
          sub.from_clause.first.range_var if sub.from_clause.size == 1 && sub.from_clause.first.node == :range_var
        end

        # Gives the subquery's table under name a fresh alias, renames every
        # column the subquery reads as name.something, and returns the
        # alias. Refuses, with nil, when a subquery inside could have a name
        # of its own that's the same.
        def rename!(sub, name, tree)
          table = renamable(sub, name)
          return unless table

          fresh = Tree::Names.new(tree).fresh(name)
          Tree.find(sub, PgQuery::ColumnRef).each { rename_column!(it, name, fresh) }
          table.alias ? table.alias.aliasname = fresh : table.alias = PgQuery::Alias.new(aliasname: fresh)
          fresh
        end

        def renamable(sub, name)
          table = Tree.from_items(sub.from_clause).find { it.name == name }&.table
          table if [PgQuery::SubLink, PgQuery::RangeSubselect].all? { Tree.find(sub, it).empty? }
        end

        def rename_column!(column, name, fresh)
          Tree.qualify!(column, fresh) if column.fields.size > 1 && column.fields.first.string&.sval == name
        end

        # Makes top read the subquery's FROM, filtered by its WHERE and an
        # EXISTS over the original's FROM and its other conditions, with x
        # = y.
        def flip!(top, others, link, column)
          sub = link.subselect.select_stmt
          exists = exists_over(top, others + [equals(link.testexpr, column)])
          top.from_clause.replace(sub.from_clause.to_a)
          top.where_clause = Tree.all_of(Tree.conjuncts(sub.where_clause) + [exists])
        end

        # An EXISTS over top's FROM with conditions.
        def exists_over(top, conditions)
          exists = Tree.exists
          inner = exists.sub_link.subselect.select_stmt
          inner.from_clause.replace(top.from_clause.to_a)
          inner.where_clause = Tree.all_of(conditions)
          exists
        end

        # left = column, with the operator IN would use.
        def equals(left, column)
          condition = Tree.where_of("SELECT WHERE 1 = 1")
          condition.a_expr.lexpr = left
          condition.a_expr.rexpr = PgQuery::Node.new(column_ref: column)
          condition
        end

        def string(sval) = PgQuery::Node.new(string: PgQuery::String.new(sval:))
      end
    end
  end
end
