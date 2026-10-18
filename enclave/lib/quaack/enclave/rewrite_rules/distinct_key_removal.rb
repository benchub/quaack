# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "input_order"
require_relative "distinct_key_removal/from"
require_relative "distinct_key_removal/keys"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' distinct_key_removal. An ORM that may
      # join a has-many association adds DISTINCT, and keeps it when the
      # joins it made are all to-one:
      #
      #   SELECT DISTINCT posts.* FROM posts JOIN users ON users.id = posts.user_id WHERE users.name = $1
      #
      # Postgres sorts or hashes every row to find duplicates that can't be
      # there. users.id is unique, so each row of posts joins at most one
      # row of users, and the join gives each row of posts at most once.
      # posts.id is unique and not null and in the select list, so no two
      # of those rows are equal, and the DISTINCT removes nothing. It's the
      # same as
      #
      #   SELECT posts.* FROM posts JOIN users ON users.id = posts.user_id WHERE users.name = $1
      #
      # The first table's key must be among the columns the DISTINCT
      # compares, and compared as its unique index compares it, which the
      # unique assumption checks. Each join's = must be the joined key's
      # own, or two rows of the joined table could match one row.
      #
      # It removes the DISTINCT of one SELECT, at any depth, and states the
      # first table's key unique with each of its columns not null, and
      # each joined table's key unique. It gives one rewrite per SELECT it
      # can take, each from the original, so the generator's second pass
      # takes two. ORDER BY, LIMIT, and OFFSET stay as they were: with
      # DISTINCT, every ORDER BY item is in the select list, and the rows
      # they order are the same.
      #
      # It's conservative. It fires only when all of this holds, and
      # otherwise gives nothing:
      #
      # - The SELECT has a plain DISTINCT: no DISTINCT ON, no GROUP BY,
      #   whose grouping sets can repeat a key as NULL, and no locking
      #   clause, which Postgres refuses with DISTINCT and would take
      #   without it. With no GROUP BY, an aggregate or a HAVING makes the
      #   SELECT one group, and Postgres then refuses the key's bare
      #   column, so those need no check of their own.
      # - Its FROM is one plain table, then inner or left joins to plain
      #   tables (see From).
      # - Each join's ON ANDs a plain = for every column of a unique key of
      #   the joined table, with a column of a table before it (see
      #   Keys.paired). Other conditions there only filter, and may stay.
      # - The select list holds every column of a unique, not-null key of
      #   the first table, with no nondeterministic collation (see
      #   Keys.root).
      # - No function or operator the select list calls, in a subquery
      #   too, could return a set or be an aggregate or window function
      #   (Catalog#row_wise?). A set-returning call gives several rows for
      #   one row of the FROM, which the DISTINCT may merge. A window
      #   function runs before the DISTINCT and doesn't change which rows
      #   it sees, but v1 refuses one too, as it does an aggregate in a
      #   subquery.
      # - If it's an arm of a UNION, INTERSECT, or EXCEPT, its select list
      #   holds no bare constant or parameter, whose type the DISTINCT
      #   settles.
      # - Nothing in the statement reads the order rows come in, such as
      #   string_agg with no ORDER BY of its own over a derived table
      #   (InputOrder), since without the DISTINCT they can come in
      #   another order.
      class DistinctKeyRemoval
        # One SELECT the rule can take, and what its rewrite rests on.
        Removal = Data.define(:select, :assumptions)

        def name = "distinct_key_removal"

        def description
          "A SELECT DISTINCT loses its DISTINCT when its select list holds a unique, not-null key of its first table " \
            "and each of its joins matches at most one row, by a unique key of the joined table."
        end

        def rewrites(parse, catalog, _literals = nil)
          Array.new(removals(parse.tree, catalog).size) do |i|
            tree = Deparse.copy(parse.tree)
            removal = removals(tree, catalog)[i]
            removal.select.distinct_clause.clear
            Rewrite.new(tree:, assumptions: removal.assumptions)
          end
        end

        private

        # Every SELECT in tree whose DISTINCT the rule can remove, in tree
        # order.
        def removals(tree, catalog)
          return [] if InputOrder.sensitive?(tree, catalog)

          selects = Tree.find_all(tree, PgQuery::SelectStmt)
          arms = selects.reject { it.op == :SETOP_NONE }.flat_map { [it.larg, it.rarg] }
          selects.filter_map { removal(it, catalog) unless untyped_arm?(it, arms) }
        end

        # Whether select is an arm of a set operation and selects an untyped
        # constant or parameter. Its DISTINCT resolves that to text, and
        # without one it takes the other arm's type, which can compare
        # otherwise, as citext does.
        def untyped_arm?(select, arms)
          arms.any? { it.equal?(select) } &&
            select.target_list.any? { %i[a_const param_ref].include?(it.res_target.val.node) }
        end

        def removal(select, catalog)
          from = From.read(select.from_clause) if distinct?(select) && row_wise?(select, catalog)
          assumptions = keys(select, from, catalog) if from
          Removal.new(select:, assumptions:) if assumptions
        end

        def row_wise?(select, catalog) = catalog.row_wise?(select.target_list.map { it.res_target.val })

        # The assumptions that state the first table's key and every
        # joined table's, each once, or nil unless there's each of them.
        def keys(select, from, catalog)
          root = Keys.root(select, from.root, catalog)
          joins = from.joins.map { Keys.join(it, catalog) }
          (root + joins.flatten(1)).uniq if root && joins.all?
        end

        def distinct?(select)
          select.distinct_clause.size == 1 && select.distinct_clause.first.node.nil? && select.group_clause.empty? &&
            select.locking_clause.empty?
        end
      end
    end
  end
end
