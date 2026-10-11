# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "not_in_to_not_exists/build"
require_relative "not_in_to_not_exists/columns"
require_relative "not_in_to_not_exists/links"
require_relative "not_in_to_not_exists/shadows"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' not_in_to_not_exists. An ORM that excludes the rows a
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
      # A row works the same way, column by column:
      #
      #   (t.a, t.b) NOT IN (SELECT s.x, s.y ...)
      #
      # becomes NOT EXISTS (... AND t.a = s.x AND t.b = s.y). Postgres
      # compares the rows with each pair's own =, ANDed, so with no NULL on
      # either side each comparison is true or false and the two agree. One
      # NULL anywhere would make a comparison unknown when the other pairs
      # match, which NOT IN drops and NOT EXISTS keeps, so every column on
      # both sides must be not null. Postgres also refuses a row comparison
      # unless each pair's = is an operator of a btree family, as box's
      # isn't, so the rule asks Postgres whether it takes each pair (see
      # Catalog#row_equality?): NOT EXISTS would give rows where NOT IN is
      # an error.
      #
      # A UNION, or UNION ALL, of SELECTs becomes one NOT EXISTS per branch,
      # ANDed in the NOT IN's place:
      #
      #   t.x NOT IN (SELECT s.y ... UNION SELECT r.z ...)
      #
      # becomes NOT EXISTS (... AND t.x = s.y) AND NOT EXISTS (... AND t.x = r.z).
      # x is in a UNION when it's in one of its branches, and one that
      # dedupes keeps every value it drops a copy of, so with no NULL in any
      # branch the two agree. That needs every branch's selected columns not
      # null, and each branch's column in a place of the same type and
      # collation as the others': the UNION compares as its columns' common
      # type, so a numeric branch under a float8 one would be compared as
      # float8 by NOT IN and as numeric by NOT EXISTS. A UNION that dedupes
      # also needs a type Postgres can dedupe, which box isn't, or NOT IN
      # is an error (see Catalog#unionable?). INTERSECT and EXCEPT
      # are refused: x is in an INTERSECT when it's in every branch, which
      # would be an OR of NOT EXISTS, and an EXCEPT's rows hang on which
      # values the other branch has, not on x.
      #
      # It gives one rewrite per NOT IN or <> ALL it can rewrite, each changing
      # only that one, and each stating each tested column and the column
      # selected in its place not null.
      #
      # It's conservative. It fires only when all of this holds, and
      # otherwise gives nothing:
      #
      # - The statement is a SELECT, and the condition is in an expression of
      #   one of its plain (not set operation) SELECTs, at any depth: a
      #   WHERE, a HAVING, a select list, a join's ON, a CASE, under an OR
      #   or a NOT, in a subquery, a FROM subquery, or a WITH. The condition
      #   belongs to the nearest SELECT around it, the one whose FROM its
      #   tested columns name (see Links). The not-null proof below is what
      #   makes the position safe: NOT IN is NULL, not false, for a NULL
      #   tested value or a NULL the subquery holds that no value matches,
      #   and NOT EXISTS is true there, a difference a WHERE hides but a
      #   select list, a CASE, or a NOT shows. With every column proven not
      #   null the condition is only ever true or false, so NOT EXISTS
      #   gives the same value in every position. The one thing that makes
      #   a not null column NULL in a row is a grouping set (ROLLUP, CUBE,
      #   GROUPING SETS) in the SELECT's GROUP BY, which is refused.
      # - It's written NOT IN or NOT (... IN ...), or x <> ALL (SELECT ...)
      #   of one column, which is true when no row the subquery gives equals
      #   x and so is the same as NOT IN. That needs the <> to be the
      #   negator of the = between the two columns, both pg_catalog's and
      #   taking exactly the columns' types, as Postgres picks them (see
      #   Catalog#negated_equality?). Another operator, ANY, and a row of
      #   columns <> ALL are refused.
      # - The NOT IN tests name.x, or a row of one or more such columns,
      #   where each name is a table in the outer FROM that
      #   Tree.plain_table_named accepts: so no outer join can fill it with
      #   NULLs.
      # - The subquery is one plain SELECT (see Tree.plain_select?), or a
      #   UNION or UNION ALL, nested any way, of such SELECTs, with no WITH,
      #   ORDER BY, or LIMIT of its own. A VALUES list is refused. A plain
      #   DISTINCT is dropped, since NOT IN doesn't count rows. Each SELECT's
      #   select list is only name2.y, one such column for each column NOT
      #   IN tests, where name2 is a table in that SELECT's own FROM that
      #   Tree.plain_table_named accepts.
      # - The catalog proves every tested and selected column not null (see
      #   Catalog). A column whose type is a domain with NOT NULL doesn't
      #   count: Postgres lets such a column hold NULL, as when an INSERT
      #   copies a scalar subquery that found no row.
      # - The correlation can read the outer row. If a SELECT's FROM has an
      #   item under the name of an outer table NOT IN tests, as an ORM
      #   that never aliases a table writes, each such item gets an alias no
      #   name in the query uses, and every column of it is renamed. That
      #   needs every column in that SELECT written name.column, and no
      #   subquery inside it, in its FROM or anywhere else, or the columns
      #   to rename can't all be found.
      #
      # What it doesn't check is that = gives true or false for two values
      # that aren't NULL. Every = Postgres ships does.
      class NotInToNotExists
        def name = "not_in_to_not_exists"

        def description
          "A NOT IN subquery whose tested columns and selected columns are all not null becomes a NOT EXISTS " \
            "correlated on each pair."
        end

        def rewrites(parse, catalog, _literals = nil)
          return [] unless Tree.select(parse.tree)

          Array.new(Links.all(parse.tree).size) { rewrite(parse.tree, it, catalog) }.compact
        end

        private

        # A copy of the tree with the index-th NOT IN or <> ALL rewritten,
        # or nil if this rule doesn't apply to it.
        def rewrite(original, index, catalog)
          tree = Deparse.copy(original)
          found = Links.all(tree)[index]
          select = found.owner
          link = found.link
          branches = tested(link) && branches(link.subselect.select_stmt)
          assumptions = branches && order_proof(found) && proven(select, link, branches, catalog)
          return unless assumptions

          correlate!(found, branches, Tree::Names.new(tree))
          Rewrite.new(tree:, assumptions: assumptions.uniq)
        end

        # Whether the NOT IN or <> ALL can only be true or false where it
        # is, which the not-null proof gives it unless a grouping set makes
        # a tested grouped column NULL in a row of its own. A <> ALL also
        # tests one column, not a row, whose <> is the negation of =.
        def order_proof(found)
          Tree.find(found.owner.group_clause, PgQuery::GroupingSet).empty? && !repeated?(found) &&
            (found.link.sub_link_type == :ANY_SUBLINK || tested(found.link).size == 1)
        end

        # Whether the SELECT holds another copy of the NOT IN and one copy
        # is in its GROUP BY, DISTINCT ON, or ORDER BY, where Postgres needs
        # the copies to match: rewriting one would make the query fail to plan.
        def repeated?(found)
          select = found.owner
          link = unlocated(found.link)
          copies = ->(node) { Tree.find_all(node, PgQuery::SubLink).count { unlocated(it) == link } }
          clauses = [select.group_clause, select.distinct_clause, select.sort_clause]
          copies.call(select) > 1 && clauses.any? { copies.call(it).positive? }
        end

        # A copy of node with every location cleared, to compare.
        def unlocated(node) = Deparse.copy(node).tap { Deparse.clear_locations(it) }

        # The rewrite's assumptions, if the catalog proves them and NOT
        # EXISTS compares as NOT IN does, or nil.
        def proven(select, link, branches, catalog)
          assumptions = assumptions(select, tested(link), branches)
          assumptions if assumptions&.all? { catalog.met?(it) } && comparable?(select, link, branches, catalog)
        end

        # The ColumnRefs NOT IN tests: the one column, or each of the row's,
        # or nil if anything it tests isn't a column.
        def tested(link)
          columns = link.testexpr.node == :row_expr ? link.testexpr.row_expr.args : [link.testexpr]
          columns.map(&:column_ref) if columns.any? && columns.all? { it.node == :column_ref }
        end

        # The SELECTs whose rows the subquery is: itself, or each branch of
        # a UNION or UNION ALL with no WITH, ORDER BY, or LIMIT of its own,
        # or nil for any other set operation.
        def branches(sub)
          return [sub] if sub.op == :SETOP_NONE
          return unless sub.op == :SETOP_UNION && Tree.unlimited?(sub) && sub.with_clause.nil?

          left = branches(sub.larg)
          right = branches(sub.rarg)
          left + right if left && right
        end

        # That each tested column and the one each branch selects in its
        # place are not null, pair by pair, or nil if any isn't a column of
        # a table no outer join can fill with NULLs, or a branch isn't one
        # plain SELECT of as many columns as NOT IN tests.
        def assumptions(select, tested, branches)
          return unless branches.all? { Tree.plain_select?(it) && it.target_list.size == tested.size }

          pairs = branches.flat_map { |sub| tested.zip(sub.target_list).flat_map { pair(select, sub, *it) } }
          pairs if pairs.all?
        end

        # That a tested column and the target selected in its place are
        # not null, each nil if it isn't a column of a plain table.
        def pair(select, sub, column, target)
          [not_null(Columns.outer(select, column)), not_null(Columns.inner(sub, target))]
        end

        def not_null(column)
          schema, table, name = column
          { "kind" => "not_null", "table" => "#{schema}.#{table}", "column" => name } if column
        end

        # Whether NOT EXISTS compares as NOT IN does: the branches' columns
        # in each place have one type and collation, which Postgres can
        # dedupe if the UNION does, Postgres takes each pair of a row, and
        # every branch's correlation can read the outer row.
        def comparable?(select, link, branches, catalog)
          tested = tested(link)
          Columns.same_types?(link.subselect.select_stmt, branches, catalog) &&
            Columns.row_equalities?(select, tested, branches, catalog) &&
            (link.sub_link_type == :ANY_SUBLINK || Columns.negated_equalities?(select, tested, branches, catalog)) &&
            branches.all? { Shadows.correlatable?(tested, it) }
        end

        # Makes the NOT IN, or the <> ALL, a NOT EXISTS of its first branch,
        # and ANDs a NOT EXISTS of each other branch with it, each asking
        # that the tested columns equal the ones selected in their place.
        def correlate!(found, branches, names)
          link = found.link
          tested = tested(link)
          branches.each do |sub|
            Shadows.unshadow!(tested, sub, names)
            exists!(sub, tested)
          end
          Build.replace!(found, Build.exists_of(link, branches.first), branches)
        end

        # Makes sub a SELECT 1 of its rows whose selected columns each equal
        # the tested column in their place.
        def exists!(sub, tested)
          equal = tested.zip(sub.target_list).map { |column, target| Build.equals(column, target.res_target.val) }
          sub.where_clause = Tree.all_of(Tree.conjuncts(sub.where_clause) + equal)
          sub.target_list.replace(Build.one)
          sub.distinct_clause.clear
        end
      end
    end
  end
end
