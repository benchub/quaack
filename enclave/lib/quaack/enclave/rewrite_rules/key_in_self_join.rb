# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "key_in_self_join/arm"
require_relative "key_in_self_join/columns"

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
      # = ANY (subquery), or = SOME, is the same test as IN: Postgres reads
      # IN as = ANY.
      #
      # It gives one rewrite per IN it can rewrite, each changing only that
      # IN, and each stating k unique and k not null. With two or more, it
      # gives first one rewrite that changes every one of them and states
      # all their assumptions, so a query with more INs than the
      # generator's DEPTH still gets its fully rewritten form.
      #
      # It's conservative. It fires only when all of this holds, and
      # otherwise gives nothing:
      #
      # - The statement is one SELECT, and the IN is one of the conditions
      #   ANDed together in the WHERE of a plain SELECT anywhere in it (the
      #   top one, an arm of a UNION, a subquery, a FROM subquery, or a
      #   WITH), or in the ON of a join. Elsewhere (under OR or NOT, in a
      #   select list or a HAVING) the rewrite's NULL for the IN's false
      #   could show, or the moved predicates would need to be grouped.
      #   A WHERE or an ON keeps only the rows its conditions make true,
      #   so there NULL and false are the same.
      # - The IN tests name.k, where name is a table among the FROM items
      #   the condition can name: the SELECT's FROM for a WHERE, the join's
      #   two sides for an ON. Or it tests a bare k, which the catalog
      #   finds in just one of those items, each a plain table (see
      #   Columns). The table is schema-qualified, read without ONLY and
      #   without column aliases, not on the nullable side of an outer
      #   join among those items, and not inside a join that has an alias.
      #   Every other of those items has a name it can read. A table on
      #   the nullable side of an outer join could be its NULL row, which
      #   IN never matches but the moved predicates might, as t.x IS NULL
      #   would; an ON sees the join's own sides before that join fills
      #   them with NULLs, so a LEFT JOIN's right table is fine in its own
      #   ON.
      # - The catalog proves k unique and not null (see Catalog).
      # - Each arm selects only name2.k, or a bare k of name2, where name2
      #   is the same table (see Arm for the rest an arm must meet).
      class KeyInSelfJoin
        # The equality an ANY sublink may name: none, for IN, or a bare =.
        EQUALITIES = [[], ["="]].freeze

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

        # A place an IN can be: owner's field, the conditions it ANDs, and
        # scope, the FROM items they can name. That's a SELECT's WHERE and
        # FROM, or a join's ON and its two sides.
        Site = Data.define(:owner, :field, :scope) do
          def conditions = Tree.conjuncts(owner.public_send(field))

          def conditions=(nodes)
            owner.public_send(:"#{field}=", Tree.all_of(nodes))
          end
        end

        def name = "key_in_self_join"

        def description
          "An IN subquery that reads the outer table again by a unique, not-null key becomes that table's own " \
            "predicates, and an EXISTS on what's left of the subquery."
        end

        def rewrites(parse, catalog, _literals = nil)
          found = found(parse.tree, catalog)
          each = found.map { [it] }
          each.unshift(found) if found.size > 1
          each.map { rewrite(parse.tree, it, catalog) }
        end

        private

        # [site, condition] indexes of each IN it can rewrite, in tree
        # order.
        def found(tree, catalog)
          sites(tree).each_with_index.flat_map do |site, at|
            site.conditions.each_with_index.filter_map do |condition, index|
              [at, index] if match(site, condition, catalog)&.proven?(catalog)
            end
          end
        end

        # Every Site of the tree, in tree order, when it's one SELECT.
        def sites(tree)
          return [] unless Tree.select(tree)

          Tree.find_all(tree, PgQuery::SelectStmt).flat_map do |select|
            joins = select.from_clause.flat_map { Tree.joins(it) }
            [Site.new(owner: select, field: :where_clause, scope: select.from_clause.to_a),
             *joins.map { Site.new(owner: it, field: :quals, scope: [it.larg, it.rarg]) }]
          end
        end

        # A copy of the tree with the INs at chosen, found's indexes,
        # rewritten.
        def rewrite(original, chosen, catalog)
          tree = Deparse.copy(original)
          names = Tree::Names.new(tree)
          sites = sites(tree)
          assumptions = chosen.group_by(&:first).flat_map do |at, pairs|
            replace(sites[at], pairs.map(&:last), names, catalog)
          end
          Rewrite.new(tree:, assumptions: assumptions.uniq)
        end

        # Rewrites site's conditions at indexes, and gives their
        # assumptions.
        def replace(site, indexes, names, catalog)
          matches = []
          site.conditions = site.conditions.each_with_index.flat_map do |condition, index|
            next [condition] unless indexes.include?(index)

            matches << match(site, condition, catalog)
            matches.last.conditions(names)
          end
          matches.flat_map(&:assumptions)
        end

        def match(site, condition, catalog)
          outer, key = tested(condition, site.scope, catalog)
          table = Tree.plain_table_named(site.scope, outer)
          arms = table && Arm.all(condition.sub_link.subselect.select_stmt, table, key, catalog)
          Match.new(outer:, table:, key:, arms:) if arms
        end

        # [name, column] for a condition that is a column IN (subquery),
        # or = ANY, read among scope's items (see Columns), or nil.
        def tested(condition, scope, catalog)
          link = condition.sub_link if condition.node == :sub_link
          return unless link && equality?(link) && link.testexpr.node == :column_ref

          Columns.new(items: Tree.from_items(scope), catalog:).resolve(link.testexpr.column_ref)
        end

        def equality?(link)
          link.sub_link_type == :ANY_SUBLINK && EQUALITIES.include?(link.oper_name.map { it.string&.sval })
        end
      end
    end
  end
end
