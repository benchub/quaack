# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "unused_join_removal/candidates"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' left_join_to_inner. Rails' eager_load, and
      # includes with references, join a belongs_to association with a LEFT
      # OUTER JOIN, even when every row has one:
      #
      #   SELECT p.id, u.name FROM posts p LEFT JOIN users u ON u.id = p.user_id ORDER BY u.name LIMIT 20
      #
      # Postgres makes a LEFT JOIN inner when the WHERE drops its
      # NULL-extended rows, and never otherwise. A validated, immediate
      # foreign key from posts.user_id to users.id, with user_id not null,
      # means every row of posts has exactly one row of users with that id,
      # so the LEFT JOIN extends no row with NULLs, and it's the same as
      #
      #   SELECT p.id, u.name FROM posts p JOIN users u ON u.id = p.user_id ORDER BY u.name LIMIT 20
      #
      # An inner join's tables can go in either order, so users can drive a
      # nested loop in name order and stop after 20 rows.
      #
      # Each rewrite makes one join inner and states the foreign key and each
      # of its columns not null. It gives one rewrite per join it can change,
      # each from the original, so the generator's second pass changes two,
      # and a join from a table that another LEFT JOIN brings in, once that
      # one is inner.
      #
      # It's conservative. It fires only when all of this holds, and
      # otherwise gives nothing:
      #
      # - The join is a LEFT JOIN with an ON, in any FROM at any depth. A
      #   NATURAL or USING join has none. It may have an alias, which hides
      #   nothing its ON reads.
      # - Its right side is a schema-qualified table, read without ONLY and
      #   without column aliases (Tree.plain_table?).
      # - Every condition its ON ANDs is a plain unqualified = between two
      #   columns written name.column: one of the joined table, the other of
      #   one joining table. That table is a plain table of the join's left
      #   side that no outer join there can fill with NULLs
      #   (Tree.plain_table_named), since a NULL-extended row of it matches
      #   no row. Any other condition, on either side, blocks the rule,
      #   since the LEFT JOIN keeps the rows it fails.
      # - The catalog proves a foreign key from exactly those joining
      #   columns to exactly those columns of the joined table, pair for
      #   pair (Catalog#strict_foreign_key?, as unused_join_removal asks),
      #   the joined table with no row-level security, and every joining
      #   column not null.
      # - Nowhere does the query have a locking clause. A FOR UPDATE that
      #   reaches a LEFT JOIN's nullable side fails, but on an inner join it
      #   runs and locks that table's rows. QUAACK refuses such queries
      #   before any rule runs, and the rule checks again.
      class LeftJoinToInner
        # One LEFT JOIN the rule might make inner: the JoinExpr, the joining
        # table's RangeVar, the joined table's, and the [joining column,
        # joined column] pairs of its ON.
        Change = Data.define(:join, :joining, :joined, :pairs)

        def name = "left_join_to_inner"

        def description
          "A LEFT JOIN on a validated foreign key whose columns are all not null, from a table the join's left " \
            "side can't fill with NULLs, becomes an inner join."
        end

        def rewrites(parse, catalog, _literals = nil)
          Array.new(changes(parse.tree, catalog).size) do |i|
            tree = Deparse.copy(parse.tree)
            change = changes(tree, catalog)[i]
            change.join.jointype = :JOIN_INNER
            Rewrite.new(tree:, assumptions: assumptions(change))
          end
        end

        private

        # Every LEFT JOIN the rule can make inner in tree, in tree order.
        def changes(tree, catalog)
          return [] unless Tree.find_all(tree, PgQuery::LockingClause).empty?

          Tree.find_all(tree, PgQuery::JoinExpr).filter_map { change(it) }.select { proven?(it, catalog) }
        end

        # A Change of join, or nil unless it has the rule's shape. The pairs
        # are read as unused_join_removal reads an inner join's.
        def change(join)
          joined = joined(join)
          return unless joined

          sides = Tree.conjuncts(join.quals).map { UnusedJoinRemoval::Candidates.sides(it, Tree.refname(joined)) }
          joining = UnusedJoinRemoval::Candidates.joining([join.larg], sides)
          Change.new(join:, joining:, joined:, pairs: sides.map { it.drop(1) }) if joining
        end

        # The RangeVar of a LEFT JOIN's right side, when it's a plain table,
        # or nil.
        def joined(join)
          table = join.rarg.range_var if join.jointype == :JOIN_LEFT && join.rarg.node == :range_var
          table if table && Tree.plain_table?(table)
        end

        def proven?(change, catalog)
          catalog.strict_foreign_key?(pair(change.joining), pair(change.joined), change.pairs) &&
            assumptions(change).all? { catalog.met?(it) }
        end

        def pair(range) = [range.schemaname, range.relname]

        def assumptions(change)
          table = pair(change.joining).join(".")
          [{ "kind" => "foreign_key", "table" => table, "columns" => change.pairs.map(&:first),
             "references_table" => pair(change.joined).join("."), "references_columns" => change.pairs.map(&:last) },
           *change.pairs.map { { "kind" => "not_null", "table" => table, "column" => it.first } }]
        end
      end
    end
  end
end
