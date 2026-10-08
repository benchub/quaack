# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "key_in_self_join/arm"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' key_in_self_join. An ORM that filters a table by a
      # subquery on the same table writes
      #
      #   SELECT ... FROM t WHERE t.k IN (SELECT t2.k FROM t t2 JOIN r ON r.t_id = t2.id WHERE t2.x = $1)
      #
      # which reads t twice. When k is unique and not null, the t2 row the
      # subquery finds for an outer row is that row itself, so t2's
      # conditions can be asked of the outer row, and only the other tables
      # are left to look for:
      #
      #   SELECT ... FROM t WHERE t.x = $1 AND EXISTS (SELECT 1 FROM r r_1 WHERE r_1.t_id = t.id)
      #
      # With no other tables there's no EXISTS, and with no conditions
      # either, the IN becomes true. A subquery that's a UNION or UNION ALL
      # of such SELECTs is rewritten arm by arm, and the arms are joined
      # with OR. Each table left in an EXISTS gets an alias no name in the
      # query uses, since the subquery's names may be the outer query's too.
      #
      # It gives one rewrite per IN it can rewrite, each changing only that
      # IN, and each stating k unique and k not null.
      #
      # It's conservative. It fires only when all of this holds, and
      # otherwise gives nothing:
      #
      # - The query is one SELECT, and the IN is one
      #   of the conditions its WHERE ANDs together. Elsewhere (under OR or
      #   NOT, in a select list or a join's ON) the rewrite's NULL for the
      #   IN's false could show.
      # - The IN tests name.k, where name is a table in the outer FROM:
      #   schema-qualified, read without ONLY and without column aliases,
      #   not on the nullable side of an outer join, and not inside a join
      #   that has an alias. Every other FROM item has a name it can read.
      # - The catalog proves k unique and not null (see Catalog).
      # - Each arm selects only name2.k, where name2 is the same table (see
      #   Arm for the rest an arm must meet).
      class KeyInSelfJoin
        # One IN it can rewrite: the name the outer query reads the table
        # by, the table's RangeVar, the key, and the subquery's arms.
        Match = Data.define(:outer, :table, :key, :arms) do
          def assumptions
            table_name = "#{table.schemaname}.#{table.relname}"
            [{ "kind" => "unique", "table" => table_name, "columns" => [key] },
             { "kind" => "not_null", "table" => table_name, "column" => key }]
          end

          def proven?(catalog) = assumptions.all? { catalog.met?(it) }

          # The conditions that take the IN's place among the WHERE's.
          def conditions(names)
            each = arms.map { it.conditions(outer, names) }
            each.size == 1 ? each.first : [Tree.any_of(each.map { Tree.all_of(it) })]
          end
        end

        def name = "key_in_self_join"

        def description
          "An IN subquery that reads the outer table again by a unique, not-null key becomes that table's own " \
            "predicates, and an EXISTS on what's left of the subquery."
        end

        def rewrites(parse, catalog, _literals = nil)
          count = Tree.conjuncts(Tree.select(parse.tree)&.where_clause).size
          Array.new(count) { rewrite(parse.tree, it, catalog) }.compact
        end

        private

        # A copy of the tree with the WHERE's index-th condition rewritten,
        # or nil if this rule doesn't apply to it.
        def rewrite(original, index, catalog)
          tree = Deparse.copy(original)
          select = Tree.select(tree)
          conditions = Tree.conjuncts(select.where_clause)
          match = match(select, conditions[index])
          return unless match&.proven?(catalog)

          conditions[index, 1] = match.conditions(Tree::Names.new(tree))
          select.where_clause = Tree.all_of(conditions)
          Rewrite.new(tree:, assumptions: match.assumptions)
        end

        def match(select, condition)
          outer, key = tested(condition)
          table = Tree.plain_table_named(select.from_clause, outer)
          arms = table && Arm.all(condition.sub_link.subselect.select_stmt, table, key)
          Match.new(outer:, table:, key:, arms:) if arms
        end

        # [name, column] for a condition that is name.column IN (subquery),
        # or nil.
        def tested(condition)
          link = condition.sub_link if condition.node == :sub_link
          return unless link && link.sub_link_type == :ANY_SUBLINK && link.oper_name.empty?

          Tree.qualified(link.testexpr.column_ref) if link.testexpr.node == :column_ref
        end
      end
    end
  end
end
