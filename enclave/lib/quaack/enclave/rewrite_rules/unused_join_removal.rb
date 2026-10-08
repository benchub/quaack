# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "unused_join_removal/candidates"
require_relative "unused_join_removal/reads"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' unused_join_removal. An ORM that filters or
      # eager-loads through an association often keeps a join to a table it
      # then reads nothing of:
      #
      #   SELECT p.id, p.title FROM posts p JOIN users u ON p.user_id = u.id WHERE p.title <> $1
      #
      # Postgres removes an unused LEFT JOIN to a unique key, but never an
      # inner one, since an inner join can drop rows. It can't here: a
      # validated, immediate foreign key from posts.user_id to users.id,
      # with user_id not null, means every row of posts has exactly one row
      # of users with that id. So the join gives each row of posts exactly
      # once, and with users read nowhere else it's the same as
      #
      #   SELECT p.id, p.title FROM posts p WHERE p.title <> $1
      #
      # Each rewrite removes one join and states the foreign key and each of
      # its columns not null. It gives one rewrite per join it can remove,
      # each from the original, so the generator's second pass removes two.
      #
      # It's conservative. It fires only when all of this holds, and
      # otherwise gives nothing:
      #
      # - The join is in the FROM of some SELECT, at any depth. It's either
      #   an inner JOIN, not NATURAL, with no USING and no alias, one side
      #   of which is the joined table, or the joined table is an item of a
      #   comma-separated FROM of two items or more.
      # - The joined table is a schema-qualified table, read without ONLY
      #   and without column aliases (Tree.plain_table?).
      # - The join's conditions, every condition the JOIN's ON ANDs or, for
      #   a comma join, the conjuncts of the WHERE's top-level AND that
      #   compare a column of the joined table with another's, are each a
      #   plain unqualified = between two columns written name.column: one
      #   of the joined table, the other of one joining table. That table is
      #   a plain table of the other side of the JOIN, or of the comma
      #   join's other items, that no outer join there can fill with NULLs
      #   (Tree.plain_table_named).
      # - The catalog proves a foreign key from exactly those joining
      #   columns to exactly those columns of the joined table, pair for
      #   pair (Catalog#strict_foreign_key?): validated, not deferrable,
      #   with its triggers enabled, between two plain tables, neither with
      #   inheritance parents or children nor a partition, the joined one
      #   with no row-level security, and pairing columns of one type whose
      #   = is the key's, with no nondeterministic collation. It also proves
      #   every joining column not null. A WHERE that requires a nullable
      #   column to be non-null doesn't count in v1.
      # - The query reads the joined table nowhere else. No column
      #   reference that might resolve to it names it, other than in the
      #   conditions the rule removes: no column, no name.*, no whole row.
      #   Only references inside the SELECT that joins it might, and not a
      #   name.column or name.* that a nested SELECT's own FROM binds first
      #   (Reads), so another UNION branch, or Rails' IN (SELECT users.id
      #   FROM users ...), may use the name. No bare column in that SELECT,
      #   at any depth, has the name of one of its columns, since it might
      #   be that table's. The SELECT that joins it has no bare * in its
      #   select list. Any further condition on it, in the ON or the WHERE,
      #   blocks the rule.
      # - Nowhere does the query have a locking clause, which can name the
      #   table, or a NATURAL or USING join, whose columns are found by name.
      class UnusedJoinRemoval
        def name = "unused_join_removal"

        def description
          "An inner join to a table the query reads nowhere else, on a validated foreign key whose columns are " \
            "all not null, is removed."
        end

        def rewrites(parse, catalog, _literals = nil)
          Array.new(removals(parse.tree, catalog).size) do |i|
            tree = Deparse.copy(parse.tree)
            removal = removals(tree, catalog)[i]
            removal.remove.call
            Rewrite.new(tree:, assumptions: assumptions(removal))
          end
        end

        private

        # Every join the rule can remove from tree, in tree order.
        def removals(tree, catalog)
          return [] unless allowed?(tree)

          Candidates.in(tree).select { unread?(it, catalog) && proven?(it, catalog) }
        end

        # Whether tree has no locking clause and no NATURAL or USING join.
        def allowed?(tree)
          Candidates.every(tree, PgQuery::LockingClause).empty? &&
            Candidates.every(tree, PgQuery::JoinExpr).all? { !it.is_natural && it.using_clause.empty? }
        end

        # Whether no column reference but those in the removal's own
        # conditions might read the joined table, and the SELECT has no
        # bare *.
        def unread?(removal, catalog)
          name = Tree.refname(removal.joined)
          columns = catalog.column_names(*pair(removal.joined))
          Reads.count(removal.select, name, columns) == removal.pairs.size && !bare_star?(removal.select)
        end

        def bare_star?(select)
          select.target_list.any? do |target|
            (ref = target.res_target.val&.column_ref) && ref.fields.map(&:node) == [:a_star]
          end
        end

        def proven?(removal, catalog)
          catalog.strict_foreign_key?(pair(removal.joining), pair(removal.joined), removal.pairs) &&
            assumptions(removal).all? { catalog.met?(it) }
        end

        def pair(range) = [range.schemaname, range.relname]

        def assumptions(removal)
          table = pair(removal.joining).join(".")
          [{ "kind" => "foreign_key", "table" => table, "columns" => removal.pairs.map(&:first),
             "references_table" => pair(removal.joined).join("."), "references_columns" => removal.pairs.map(&:last) },
           *removal.pairs.map { { "kind" => "not_null", "table" => table, "column" => it.first } }]
        end
      end
    end
  end
end
