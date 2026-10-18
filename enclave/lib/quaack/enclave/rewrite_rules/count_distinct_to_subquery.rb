# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' count_distinct_to_subquery. A dashboard
      # often counts distinct values per group:
      #
      #   SELECT events.course_id, count(DISTINCT events.user_id) AS users
      #     FROM public.events WHERE events.created_at > $1 GROUP BY events.course_id
      #
      # Postgres runs count(DISTINCT) by sorting each group's values inside
      # the aggregate, and it can't hash them. A SELECT DISTINCT can hash, so
      # the rule dedupes the pairs first and counts what's left:
      #
      #   SELECT d_1.course_id, count(d_1.user_id_1) AS users
      #     FROM (SELECT DISTINCT events.course_id, events.user_id AS user_id_1
      #             FROM public.events WHERE events.created_at > $1) d_1
      #     GROUP BY d_1.course_id
      #
      # It's sound. The subquery keeps one row for each distinct (group, e)
      # pair, so every group still has a row, and counting the non-NULL e
      # of those rows counts the group's distinct non-NULL values. Both
      # forms compare e with its type's default equality and its
      # collation, and both skip a NULL e, so a group whose e is all NULL
      # still counts 0. With no GROUP BY, an empty input still gives one
      # row of 0. It states no assumption.
      #
      # The query must be a top-level SELECT with a FROM, whose select list
      # is the grouping columns, each written name.column, and exactly one
      # count(DISTINCT e) of one argument, with no FILTER and no ORDER BY of
      # its own. Its GROUP BY must be exactly those columns, as a set. Each
      # output keeps its name. An ORDER BY may name a grouping column as
      # written, which becomes the subquery's column, an output's name, or
      # an ordinal, which stay as they are. LIMIT, OFFSET, and WITH stay on
      # the outer query.
      #
      # It refuses:
      #
      # - HAVING, a window, DISTINCT, a grouping set, or a locking clause.
      # - Any other ORDER BY item.
      # - Two grouping columns of the same column name, which would clash
      #   in the subquery, or an output name that two outputs share.
      # - An e that's a bare constant or placeholder, whose type the
      #   subquery could read differently. Postgres itself refuses an
      #   aggregate, window, or set-returning call in e.
      # - A query that might call a volatile function (Catalog#calls_volatile?).
      class CountDistinctToSubquery
        COUNT = [%w[count], %w[pg_catalog count]].freeze

        def name = "count_distinct_to_subquery"

        def description
          "A count(DISTINCT e), alone or with its GROUP BY columns, counts the rows of a SELECT DISTINCT of " \
            "those columns and e, which Postgres can hash instead of sorting inside the aggregate."
        end

        def rewrites(parse, catalog, _literals = nil)
          select = Tree.select(parse.tree)
          return [] unless select && fires?(select) && !catalog.calls_volatile?(Deparse.faithfully(parse.tree))

          tree = Deparse.copy(parse.tree)
          tree.stmts.first.stmt.select_stmt = rewritten(Tree.select(tree), Tree::Names.new(tree))
          [Rewrite.new(tree:, assumptions: [])]
        rescue Deparse::Error
          []
        end

        private

        def fires?(select)
          plain?(select) && (count = count(select)) && value?(count.args.first) &&
            grouped_by_columns?(select) && unique_names?(select) && orders_by_outputs?(select)
        end

        def plain?(select)
          select.op == :SETOP_NONE && select.from_clause.any? && select.having_clause.nil? &&
            select.window_clause.empty? && select.distinct_clause.empty? && select.locking_clause.empty? &&
            !select.group_distinct && select.limit_option != :LIMIT_OPTION_WITH_TIES
        end

        # The select list's one count(DISTINCT e), when every other item is a
        # name.column.
        def count(select)
          vals = select.target_list.map { it.res_target.val }
          counts = vals.select { counted?(it) }
          counts.first.func_call if counts.one? && (vals - counts).all? { column(it) }
        end

        def counted?(node)
          call = node.func_call if node.node == :func_call
          call && COUNT.include?(call.funcname.map { it.string.sval }) && call.agg_distinct && call.args.one? &&
            call.agg_filter.nil? && call.agg_order.empty? && call.over.nil? && !call.agg_star &&
            !call.agg_within_group && !call.func_variadic
        end

        # Whether e is more than a constant or placeholder.
        def value?(node)
          node = node.type_cast.arg while node.node == :type_cast
          !%i[a_const param_ref].include?(node.node)
        end

        # [qualifier, column] of a name.column, or nil.
        def column(node) = (Tree.qualified(node.column_ref) if node.node == :column_ref)

        def columns(select) = select.target_list.filter_map { column(it.res_target.val) }

        def grouped_by_columns?(select)
          groups = select.group_clause.map { column(it) }
          groups.all? && groups.to_set == columns(select).to_set
        end

        # Whether no two grouping columns share a column name, and no two
        # outputs share a name.
        def unique_names?(select)
          names = columns(select).map(&:last)
          outputs = output_names(select)
          names.uniq.size == names.size && outputs.uniq.size == outputs.size
        end

        def output_names(select)
          select.target_list.map do |target|
            target = target.res_target
            next target.name unless target.name.empty?

            column(target.val)&.last || "count"
          end
        end

        def orders_by_outputs?(select)
          select.sort_clause.all? { sort_key(it.sort_by.node, select) }
        end

        # What an ORDER BY item becomes, given the subquery's columns: a
        # grouping column's name, :keep for an output's name or an
        # ordinal, or nil for anything else.
        def sort_key(node, select)
          return :keep if node.node == :a_const && node.a_const.val == :ival
          return :keep if node.node == :column_ref && output_names(select).include?(Tree.bare_name(node.column_ref))

          found = column(node)
          found&.last if columns(select).include?(found)
        end

        def rewritten(select, names)
          table = names.fresh("d")
          value = select.target_list.find { counted?(it.res_target.val) }.res_target
          argument = value.val.func_call.args.first
          inner = inner(select, argument, names.fresh(base(argument)))
          sort = select.sort_clause.map { sorted(it, select, table) }
          PgQuery::SelectStmt.new(
            target_list: select.target_list.map { outer_target(it.res_target, table, inner) },
            from_clause: [subquery(inner, table)],
            group_clause: select.group_clause.map { reference(table, column(it).last) },
            sort_clause: sort, limit_count: select.limit_count, limit_offset: select.limit_offset,
            limit_option: select.limit_option, with_clause: select.with_clause, op: :SETOP_NONE
          )
        end

        # The SELECT DISTINCT of select's grouping columns and the counted
        # value, as column.
        def inner(select, argument, column)
          targets = columns(select).map { PgQuery::Node.new(res_target: PgQuery::ResTarget.new(val: ref(it))) }
          targets << PgQuery::Node.new(res_target: PgQuery::ResTarget.new(name: column, val: argument))
          PgQuery::SelectStmt.new(distinct_clause: [PgQuery::Node.new], target_list: targets,
                                  from_clause: select.from_clause.to_a, where_clause: select.where_clause,
                                  limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
        end

        def outer_target(target, table, inner)
          val = if counted?(target.val)
                  call = Deparse.copy(target.val.func_call)
                  call.agg_distinct = false
                  call.args[0] = reference(table, inner.target_list.last.res_target.name)
                  PgQuery::Node.new(func_call: call)
                else
                  reference(table, column(target.val).last)
                end
          PgQuery::Node.new(res_target: PgQuery::ResTarget.new(name: target.name, val:))
        end

        def sorted(item, select, table)
          item = Deparse.copy(item)
          key = sort_key(item.sort_by.node, select)
          item.sort_by.node = reference(table, key) unless key == :keep
          item
        end

        def subquery(inner, table)
          PgQuery::Node.new(range_subselect: PgQuery::RangeSubselect.new(
            subquery: PgQuery::Node.new(select_stmt: inner), alias: PgQuery::Alias.new(aliasname: table)
          ))
        end

        def base(argument) = (argument.node == :column_ref && argument.column_ref.fields.last.string&.sval) || "value"

        def ref(names) = PgQuery::Node.new(column_ref: PgQuery::ColumnRef.new(fields: names.map { Tree.string(it) }))

        def reference(table, column) = ref([table, column])
      end
    end
  end
end
