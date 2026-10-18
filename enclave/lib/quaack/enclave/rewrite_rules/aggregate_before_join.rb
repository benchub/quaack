# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "aggregate_before_join/shape"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' aggregate_before_join. Rails counts a
      # has-many association per row with joins(:orders).group("users.id").count:
      #
      #   SELECT COUNT(*) AS count_all, users.id AS users_id FROM public.users
      #     INNER JOIN public.orders ON orders.user_id = users.id
      #     WHERE orders.status = $1 GROUP BY users.id
      #
      # Postgres joins first, so it carries every joined row, with the
      # users columns it needs, into the aggregate, which may spill. The
      # rule aggregates orders first, by the columns the join compares,
      # and joins the result:
      #
      #   SELECT quaack_pre_1.a_1 AS count_all, users.id AS users_id FROM public.users
      #     JOIN (SELECT orders.user_id, count(*) AS a_1 FROM public.orders
      #           WHERE orders.status = $1 GROUP BY orders.user_id) quaack_pre_1
      #     ON quaack_pre_1.user_id = users.id
      #
      # It's sound. The GROUP BY holds a unique, not-null key of users, so
      # each group is one row of users. Every aggregate and moved condition
      # reads only orders, so a group's aggregates read the orders rows
      # that join that user. Those are the rows whose join columns are =
      # to the user's, which are one group of the derived table: grouping
      # and the join's = agree, since each pair is of one type whose = is
      # its default btree family's, with no nondeterministic collation. So
      # each user joins at most one derived row, which holds that user's
      # aggregates, and a user with no rows to join is dropped by both. A
      # HAVING over the aggregates filters the same groups in either place.
      # It states users' key unique and each of its columns not null.
      #
      # The derived table aggregates the orders rows that join no user, or
      # one the outer conditions drop, which the original never reads. No
      # moved condition or aggregate argument can raise on some rows
      # (OrToUnion::Arms.raises?), so those rows can't raise there. An
      # aggregate's own overflow, such as a float sum's, could, in a group
      # the join then drops. v1 accepts that, and the rule's page says so.
      #
      # It fires only when all of this holds:
      #
      # - The query is one SELECT with a GROUP BY, and no DISTINCT,
      #   window, WITH, grouping set, locking clause, FETCH WITH TIES, or
      #   subquery expression.
      # - Its FROM is exactly two plain tables, in an inner join or a
      #   comma join, with no NATURAL or USING.
      # - Every column it reads is written name.column, and isn't a *.
      # - The GROUP BY's items are all columns of one table, and hold a
      #   unique, not-null key of it.
      # - Each condition the ON and WHERE AND is a join pair, or reads
      #   only one table, and at least one is a pair.
      # - The select list holds that table's columns, and calls of an
      #   aggregate (Catalog#only_aggregates?) that read only the other
      #   table, with no OVER, WITHIN GROUP, or VARIADIC.
      # - A HAVING reads the other table only in such aggregates.
      # - Each ORDER BY item is an ordinal, an output's name, or an
      #   expression of the keyed table's columns with no aggregate.
      # - Nothing might call a volatile function (Catalog#calls_volatile?).
      class AggregateBeforeJoin
        def name = "aggregate_before_join"

        def description
          "A GROUP BY of a unique, not-null key of one table, over its inner join to another table whose rows it " \
            "aggregates, aggregates that table first, by its join columns, and joins the result."
        end

        def rewrites(parse, catalog, _literals = nil)
          shape = shape(parse, catalog)
          return [] unless shape

          tree = Deparse.copy(parse.tree)
          tree.stmts.first.stmt.select_stmt = rewritten(shape, Tree::Names.new(tree))
          [Rewrite.new(tree:, assumptions: shape.assumptions)]
        rescue Deparse::Error
          []
        end

        private

        def shape(parse, catalog)
          select = Tree.select(parse.tree)
          shape = Shape.read(select, catalog) if select
          shape if shape && !catalog.calls_volatile?(Deparse.faithfully(parse.tree))
        end

        def rewritten(shape, names)
          table = names.fresh("quaack_pre")
          aggregates = {}
          targets = shape.select.target_list.map { target(it.res_target, table, aggregates, names) }
          PgQuery::SelectStmt.new(target_list: targets, from_clause: [join(shape, inner(shape, aggregates), table)],
                                  where_clause: Tree.all_of(shape.outer), **tail(shape.select))
        end

        # The clauses the outer query keeps as they are.
        def tail(select)
          { sort_clause: select.sort_clause.to_a, limit_count: select.limit_count, limit_offset: select.limit_offset,
            limit_option: select.limit_option, op: :SETOP_NONE }
        end

        # The outer select list's item for target: the keyed table's column
        # as it was, or the derived table's column for an aggregate, under
        # the aggregate's output name. aggregates gathers each aggregate
        # under its column's fresh name.
        def target(target, table, aggregates, names)
          return PgQuery::Node.new(res_target: Deparse.copy(target)) if target.val.node == :column_ref

          column = names.fresh("a")
          aggregates[column] = target.val
          res_target(ref([table, column]), Shape.output_name(target))
        end

        # The derived table: the other table's join columns, each once,
        # and the aggregates, grouped by those columns.
        def inner(shape, aggregates)
          PgQuery::SelectStmt.new(
            target_list: inner_targets(shape, aggregates), from_clause: [PgQuery::Node.new(range_var: shape.other)],
            where_clause: Tree.all_of(shape.inner), group_clause: join_columns(shape),
            having_clause: shape.select.having_clause, limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE
          )
        end

        # The other table's join columns, each once.
        def join_columns(shape) = shape.pairs.map(&:last).uniq.map { ref([Tree.refname(shape.other), it]) }

        def inner_targets(shape, aggregates)
          join_columns(shape).map { res_target(it) } + aggregates.map { |column, val| res_target(val, column) }
        end

        # The two tables, in the order the FROM had them, the other one now
        # the derived table, joined on each pair, which reads the derived
        # table's column in place of the other table's.
        def join(shape, inner, table)
          derived = PgQuery::Node.new(range_subselect: PgQuery::RangeSubselect.new(
            subquery: PgQuery::Node.new(select_stmt: inner), alias: PgQuery::Alias.new(aliasname: table)
          ))
          keyed = PgQuery::Node.new(range_var: shape.keyed)
          larg, rarg = keyed_first?(shape) ? [keyed, derived] : [derived, keyed]
          quals = Tree.all_of(shape.pairs.map { paired(it.first, Tree.refname(shape.other), table) })
          PgQuery::Node.new(join_expr: PgQuery::JoinExpr.new(jointype: :JOIN_INNER, larg:, rarg:, quals:))
        end

        def keyed_first?(shape) = Tree.from_items(shape.select.from_clause).first.table == shape.keyed

        # condition, reading table's column in place of other's.
        def paired(condition, other, table)
          condition = Deparse.copy(condition)
          [condition.a_expr.lexpr, condition.a_expr.rexpr].each do |side|
            Tree.qualify!(side.column_ref, table) if Tree.qualified(side.column_ref).first == other
          end
          condition
        end

        def res_target(val, name = "") = PgQuery::Node.new(res_target: PgQuery::ResTarget.new(name:, val:))

        def ref(names) = PgQuery::Node.new(column_ref: PgQuery::ColumnRef.new(fields: names.map { Tree.string(it) }))
      end
    end
  end
end
