# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "implied_predicate_removal/expressions"
require_relative "scalar_aggregates_to_filter/members"
require_relative "tree"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' scalar_aggregates_to_filter. A dashboard
      # often asks for several counts of one table, each its own scalar
      # subquery, and Postgres scans the table once for each:
      #
      #   SELECT (SELECT count(*) FROM public.orders WHERE status = $1) AS pending,
      #          (SELECT count(*) FROM public.orders WHERE status = $2) AS shipped
      #
      # This reads the table once, in a one-row derived table with a FILTER
      # for each member, and each subquery becomes that table's column:
      #
      #   SELECT quaack_aggs_1.a_1 AS pending, quaack_aggs_1.a_2 AS shipped
      #     FROM (SELECT count(*) FILTER (WHERE status = $1) AS a_1,
      #                  count(*) FILTER (WHERE status = $2) AS a_2 FROM public.orders) quaack_aggs_1
      #
      # A member is a select-list item that is exactly a scalar subquery
      # reading one plain table, with no join, whose select list is one
      # aggregate call with no FILTER, window, or WITHIN GROUP, and which
      # has no GROUP BY, HAVING, DISTINCT, ORDER BY, LIMIT, OFFSET, WINDOW,
      # WITH, set operation, or subquery. Each column it names is its
      # table's, under the table's name or bare and one of its columns, so
      # it reads no outer query (see Members#own_columns?). Two or more members
      # over the same table (and the same ONLY) make one derived table.
      # Its WHERE holds the conjuncts every member shares, the literal
      # oracle deciding whether two placeholders match, with the first
      # member's placeholders. Each member's FILTER holds the rest of its
      # conjuncts, in the order written, and a member with no rest gets no
      # FILTER. The derived table goes in the FROM as a comma item, or is
      # the whole FROM if there was none, and each output keeps the name
      # Postgres gave it.
      #
      # Why that's sound. The derived table has no GROUP BY, so it's one
      # row, and a comma join with one row changes no row count. A
      # member's aggregate reads exactly the rows that pass its WHERE, the
      # shared conjuncts then its FILTER, so it gives what the member gave,
      # also over no rows (count gives 0, and the others NULL, both ways).
      # Postgres evaluates a FILTER before the aggregate's arguments, so an
      # argument runs only on the rows its member read.
      #
      # Errors. A shared conjunct runs on every row of the table, before
      # any member's own guard. So only a conjunct that can't raise
      # (see harmless?) is shared, and any other stays in each member's
      # FILTER, after the conjuncts written before it. A SELECT with no
      # FROM runs every member exactly once, so with no FROM, which it
      # requires to have no WHERE, anything else is fine. With a FROM, the
      # original runs no member when the FROM gives no rows, and the
      # rewrite may still run the derived table, so every member's
      # conjuncts must be harmless, and its aggregate one of AGGREGATES,
      # over * or a bare column.
      #
      # It works on the top-level SELECT only. It refuses one with a bare
      # *, which would read the new columns too, a GROUP BY, HAVING, WINDOW,
      # or set operation, and a rewrite that might call a volatile function
      # (Catalog#calls_volatile?) or that Postgres can't prepare, as with an
      # aggregate outside the members. It states no assumptions.
      class ScalarAggregatesToFilter
        include ImpliedPredicateRemoval::Expressions
        include Members

        # Answers no placeholder as matching another, when no oracle is
        # passed in.
        module NoLiterals
          def self.same?(*) = false
        end

        def name = "scalar_aggregates_to_filter"

        def description
          "Two or more uncorrelated scalar aggregate subqueries over one table become one pass over it, " \
            "with a FILTER for each."
        end

        def rewrites(parse, catalog, literals = nil)
          tree = Deparse.copy(parse.tree)
          groups = groups(Tree.select(tree), catalog)
          return [] if groups.empty?

          names = Tree::Names.new(tree)
          groups.each { combine!(Tree.select(tree), it, names, literals || NoLiterals) }
          sql = Deparse.faithfully(tree)
          catalog.calls_volatile?(sql) || !catalog.self_contained?(sql) ? [] : [Rewrite.new(tree:, assumptions: [])]
        rescue Deparse::Error
          []
        end

        private

        # The members of top, by table, two or more to a table.
        def groups(top, catalog)
          return [] unless top && outer_fits?(top)

          members(top, catalog).group_by { [it.range.schemaname, it.range.relname, it.range.inh] }
                               .values.select { it.size > 1 }
        end

        def outer_fits?(top)
          ungrouped?(top) && (top.from_clause.any? || top.where_clause.nil?) &&
            top.target_list.none? { star?(it.res_target.val) }
        end

        def ungrouped?(top)
          top.op == :SETOP_NONE && top.group_clause.empty? && top.having_clause.nil? && top.window_clause.empty?
        end

        def star?(node)
          node.node == :column_ref && node.column_ref.fields.size == 1 && node.column_ref.fields.first.node == :a_star
        end

        def combine!(top, members, names, literals)
          shared = shared(members, literals)
          table = names.fresh("quaack_aggs")
          targets = members.map { column!(it, table, names.fresh("a"), shared, literals) }
          top.from_clause << derived(members.first.range, targets, shared, table)
        end

        # The first member's harmless conjuncts that every other member
        # has too, each once.
        def shared(members, literals)
          first, *rest = members
          first.conditions.each_with_object([]) do |condition, kept|
            next if !harmless?(condition) || has?(kept, condition, literals)

            kept << condition if rest.all? { has?(it.conditions, condition, literals) }
          end
        end

        def has?(conditions, condition, literals) = conditions.any? { same_expression?(it, condition, literals) }

        # The member's aggregate as column, with a FILTER of its conjuncts
        # that aren't shared, and the member pointed at table's column.
        def column!(member, table, column, shared, literals)
          call = requalified(PgQuery::Node.new(func_call: member.call), Tree.refname(member.range), COPY)
          call.func_call.agg_filter = Tree.all_of(member.conditions.reject { has?(shared, it, literals) })
          point!(member, table, column)
          PgQuery::Node.new(res_target: PgQuery::ResTarget.new(name: column, val: call))
        end

        def point!(member, table, column)
          member.target.name = output_name(member) if member.target.name.empty?
          member.target.val = ref([table, column])
        end

        # The name Postgres gives a scalar subquery: its one output's.
        def output_name(member)
          inner = member.select.target_list.first.res_target.name
          inner.empty? ? function_name(member.call).last : inner
        end

        def derived(range, targets, shared, table)
          from = [PgQuery::Node.new(range_var: Deparse.copy(range))]
          select = PgQuery::SelectStmt.new(target_list: targets, from_clause: from, where_clause: Tree.all_of(shared),
                                           limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
          select = requalified(PgQuery::Node.new(select_stmt: select), COPY, Tree.refname(range))
          PgQuery::Node.new(range_subselect: PgQuery::RangeSubselect.new(
            subquery: select, alias: PgQuery::Alias.new(aliasname: table)
          ))
        end

        def ref(names) = PgQuery::Node.new(column_ref: PgQuery::ColumnRef.new(fields: names.map { Tree.string(it) }))
      end
    end
  end
end
