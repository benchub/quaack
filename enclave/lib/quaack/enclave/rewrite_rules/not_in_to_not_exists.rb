# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "tree"
require_relative "not_in_to_not_exists/columns"
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
      # It gives one rewrite per NOT IN it can rewrite, each changing only
      # that NOT IN, and each stating each tested column and the column
      # selected in its place not null.
      #
      # It's conservative. It fires only when all of this holds, and
      # otherwise gives nothing:
      #
      # - The query is one SELECT, and the NOT IN is one of the conditions
      #   its WHERE ANDs together. Under an OR or a NOT, in a select list, a
      #   join's ON, or a subquery it would be as sound, but the tested
      #   column's table would have to be found in another scope.
      # - It's written NOT IN or NOT (... IN ...). <> ALL is refused, since
      #   it's only the same if <> is the negation of =.
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
          branches = link && branches(link.subselect.select_stmt)
          assumptions = branches && proven(select, link, branches, catalog)
          return unless assumptions

          correlate!(select, index, link, branches, Tree::Names.new(tree))
          Rewrite.new(tree:, assumptions: assumptions.uniq)
        end

        # The rewrite's assumptions, if the catalog proves them and NOT
        # EXISTS compares as NOT IN does, or nil.
        def proven(select, link, branches, catalog)
          assumptions = assumptions(select, tested(link), branches)
          assumptions if assumptions&.all? { catalog.met?(it) } && comparable?(select, link, branches, catalog)
        end

        # The SubLink of a condition that is name.column NOT IN (SELECT ...),
        # or a row of such columns NOT IN (SELECT ...), or nil.
        def not_in(condition)
          link = negated(condition)
          return unless link && link.sub_link_type == :ANY_SUBLINK && link.oper_name.empty?

          link if tested(link) && link.subselect.node == :select_stmt
        end

        # The ColumnRefs NOT IN tests: the one column, or each of the row's,
        # or nil if anything it tests isn't a column.
        def tested(link)
          columns = link.testexpr.node == :row_expr ? link.testexpr.row_expr.args : [link.testexpr]
          columns.map(&:column_ref) if columns.any? && columns.all? { it.node == :column_ref }
        end

        # The SubLink that condition is the NOT of, or nil.
        def negated(condition)
          return unless condition.node == :bool_expr && condition.bool_expr.boolop == :NOT_EXPR

          condition.bool_expr.args.first.sub_link
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
            branches.all? { Shadows.correlatable?(tested, it) }
        end

        # Makes the NOT IN NOT EXISTS of its first branch, and ANDs a NOT
        # EXISTS of each other branch after it, each asking that the tested
        # columns equal the ones selected in their place.
        def correlate!(select, index, link, branches, names)
          tested = tested(link)
          branches.each do |sub|
            Shadows.unshadow!(tested, sub, names)
            exists!(sub, tested)
          end
          link.sub_link_type = :EXISTS_SUBLINK
          link.testexpr = nil
          split!(select, index, link, branches) if branches.size > 1
        end

        # Makes the EXISTS the first branch's, and ANDs a NOT EXISTS of each
        # other branch after it.
        def split!(select, index, link, branches)
          link.subselect = PgQuery::Node.new(select_stmt: branches.first)
          conditions = Tree.conjuncts(select.where_clause)
          conditions.insert(index + 1, *branches.drop(1).map { not_exists(it) })
          select.where_clause = Tree.all_of(conditions)
        end

        def not_exists(sub)
          link = PgQuery::SubLink.new(sub_link_type: :EXISTS_SUBLINK, subselect: PgQuery::Node.new(select_stmt: sub))
          PgQuery::Node.new(bool_expr: PgQuery::BoolExpr.new(boolop: :NOT_EXPR,
                                                             args: [PgQuery::Node.new(sub_link: link)]))
        end

        # Makes sub a SELECT 1 of its rows whose selected columns each equal
        # the tested column in their place.
        def exists!(sub, tested)
          equal = tested.zip(sub.target_list).map { |column, target| equals(column, target.res_target.val) }
          sub.where_clause = Tree.all_of(Tree.conjuncts(sub.where_clause) + equal)
          sub.target_list.replace(one)
          sub.distinct_clause.clear
        end

        # The select list of SELECT 1.
        def one = Tree.exists.sub_link.subselect.select_stmt.target_list.to_a

        # tested = right, for a tested ColumnRef, which is copied, since
        # each branch's correlation has its own.
        def equals(tested, right)
          left = PgQuery::Node.new(column_ref: PgQuery::ColumnRef.decode(PgQuery::ColumnRef.encode(tested)))
          name = [PgQuery::Node.new(string: PgQuery::String.new(sval: "="))]
          PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind: :AEXPR_OP, name:, lexpr: left, rexpr: right))
        end
      end
    end
  end
end
