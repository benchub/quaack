# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "tree"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules's not_in_to_not_exists. An ORM that excludes the rows a
      # subquery gives writes
      #
      #   SELECT ... FROM t WHERE t.x NOT IN (SELECT s.y FROM s WHERE s.z = $1)
      #
      # which Postgres can only plan as a subplan it runs or hashes, since
      # one NULL from the subquery makes NOT IN give no rows at all. When
      # neither column can be NULL, that can't happen, and it's an anti-join:
      #
      #   SELECT ... FROM t WHERE NOT EXISTS (SELECT 1 FROM s WHERE s.z = $1 AND t.x = s.y)
      #
      # The correlation is x = y, in that order: the comparison NOT IN made,
      # so it's the same operator whatever the two types are. The rest of
      # the subquery is left as it was, so one that already reads the outer
      # row, or has subqueries of its own, is fine.
      #
      # It gives one rewrite per NOT IN it can rewrite, each changing only
      # that NOT IN, and each stating x not null and y not null.
      #
      # It's conservative. It fires only when all of this holds, and
      # otherwise gives nothing:
      #
      # - The query is one SELECT, and the NOT IN is one of the conditions
      #   its WHERE ANDs together. Under an OR or a NOT, in a select list, a
      #   join's ON, or a subquery it would be as sound, but the tested
      #   column's table would have to be found in another scope.
      # - It's written NOT IN or NOT (... IN ...). <> ALL is refused, since
      #   it's only the same if <> is the negation of =, and so is a row
      #   on the left.
      # - The NOT IN tests name.x, where name is a table in the outer FROM
      #   that Tree.plain_table_named accepts: so no outer join can fill it
      #   with NULLs.
      # - The subquery is one plain SELECT (see Tree.plain_select?), not a
      #   set operation or a VALUES list. A plain DISTINCT is dropped,
      #   since NOT IN doesn't count rows. Its select list is only name2.y,
      #   where name2 is a table in the subquery's own FROM that
      #   Tree.plain_table_named accepts.
      # - The catalog proves x and y not null (see Catalog).
      # - The correlation can read the outer row. If the subquery's FROM
      #   has an item under the outer table's name, as an ORM that never
      #   aliases a table writes, that item gets an alias no name in the
      #   query uses, and every column of it is renamed. That needs every
      #   column in the subquery written name.column, and no subquery
      #   inside it, in its FROM or anywhere else, or the columns to rename
      #   can't all be found.
      #
      # What it doesn't check is that = gives true or false for two values
      # that aren't NULL. Every = Postgres ships does.
      class NotInToNotExists
        def name = "not_in_to_not_exists"

        def description
          "A NOT IN subquery whose tested column and selected column are both not null becomes a NOT EXISTS " \
            "correlated on the two."
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
          link = not_in(Tree.conjuncts(select.where_clause)[index])
          assumptions = link && assumptions(select, link)
          return unless assumptions&.all? { catalog.met?(it) } && correlatable?(link)

          correlate!(link, Tree::Names.new(tree))
          Rewrite.new(tree:, assumptions: assumptions.uniq)
        end

        # The SubLink of a condition that is name.column NOT IN (SELECT ...),
        # or nil.
        def not_in(condition)
          link = negated(condition)
          return unless link && link.sub_link_type == :ANY_SUBLINK && link.oper_name.empty?

          link if link.testexpr.node == :column_ref && link.subselect.node == :select_stmt
        end

        # The SubLink that condition is the NOT of, or nil.
        def negated(condition)
          return unless condition.node == :bool_expr && condition.bool_expr.boolop == :NOT_EXPR

          condition.bool_expr.args.first.sub_link
        end

        # That the tested column and the selected one are not null, or nil
        # if either isn't a column of a table no outer join can fill with
        # NULLs, or the subquery isn't one plain SELECT of one column.
        def assumptions(select, link)
          sub = link.subselect.select_stmt
          return unless Tree.plain_select?(sub)

          both = [not_null(select.from_clause, Tree.qualified(link.testexpr.column_ref)),
                  not_null(sub.from_clause, selected(sub))]
          both if both.all?
        end

        # [name, column] for the subquery's select list, if it's one column
        # written name.column. A set operation and a VALUES list have no
        # select list of their own, so they give nil.
        def selected(sub)
          target = sub.target_list.first.res_target if sub.target_list.size == 1
          Tree.qualified(target.val.column_ref) if target&.val&.node == :column_ref
        end

        def not_null(from, (name, column))
          table = Tree.plain_table_named(from, name)
          { "kind" => "not_null", "table" => "#{table.schemaname}.#{table.relname}", "column" => column } if table
        end

        # Makes the NOT IN's SubLink an EXISTS whose subquery also asks that
        # the tested column equal the selected one.
        def correlate!(link, names)
          unshadow!(link, names)
          exists!(link.subselect.select_stmt, link.testexpr)
          link.sub_link_type = :EXISTS_SUBLINK
          link.testexpr = nil
        end

        # Makes sub a SELECT 1 of its rows whose selected column tested
        # equals.
        def exists!(sub, tested)
          equal = equals(tested, sub.target_list.first.res_target.val)
          sub.where_clause = Tree.all_of(Tree.conjuncts(sub.where_clause) + [equal])
          sub.target_list.replace(one)
          sub.distinct_clause.clear
        end

        # The select list of SELECT 1.
        def one = Tree.exists.sub_link.subselect.select_stmt.target_list.to_a

        def equals(left, right)
          name = [PgQuery::Node.new(string: PgQuery::String.new(sval: "="))]
          PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind: :AEXPR_OP, name:, lexpr: left, rexpr: right))
        end

        # The subquery's FROM item under the outer table's name, which
        # would hide the outer row from the correlation, or nil.
        def shadow(link)
          outer = Tree.qualified(link.testexpr.column_ref).first
          Tree.from_items(link.subselect.select_stmt.from_clause).find { it.name == outer }
        end

        # Whether the correlation can read the outer row: nothing in the
        # subquery's FROM has its name, or what has is a table that can be
        # given another alias. That needs every column the subquery reads
        # written name.column, and no deeper scope to hide a name.
        def correlatable?(link)
          shadow = shadow(link)
          return true unless shadow

          !shadow.table.nil? && columns(link).all? { Tree.qualified(it) } &&
            [PgQuery::SubLink, PgQuery::RangeSubselect].all? { Tree.find(link.subselect.select_stmt, it).empty? }
        end

        # Gives the subquery's FROM item under the outer table's name, if
        # there is one, a fresh alias, and renames its columns.
        def unshadow!(link, names)
          shadow = shadow(link)
          return unless shadow

          fresh = names.fresh(shadow.name)
          columns(link).each { Tree.qualify!(it, fresh) if Tree.qualified(it).first == shadow.name }
          realias!(shadow.table, fresh)
        end

        # Every column the subquery reads.
        def columns(link) = Tree.find(link.subselect.select_stmt, PgQuery::ColumnRef)

        def realias!(range, name)
          range.alias ? range.alias.aliasname = name : range.alias = PgQuery::Alias.new(aliasname: name)
        end
      end
    end
  end
end
