# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class CountToExists
        # The count a scalar subquery gives, and the EXISTS of the same rows.
        module Counted
          # column is the ColumnRef count(column) counts, or nil for count(*).
          Count = Data.define(:column)

          # count's name, bare or pg_catalog's.
          NAMES = [["count"], %w[pg_catalog count]].freeze

          module_function

          # The Count of a SubLink, or nil. It must be a scalar subquery that
          # gives exactly one row (see one_row), whose select list is only
          # count(*) or count(column), pg_catalog's by name or bare, with
          # no DISTINCT, ORDER BY, FILTER, or OVER. A count of anything
          # else, such as count(1), whose 1 is a placeholder, or an
          # expression, is refused. So is a column the rule can't place (see
          # column?).
          def read(link, catalog)
            select = one_row(link)
            call = counted(select) if select
            return unless call
            return Count.new(column: nil) if call.agg_star

            arg = call.args.first
            Count.new(column: arg.column_ref) if arg.node == :column_ref && column?(select, arg.column_ref, catalog)
          end

          # Makes select SELECT 1 of the rows it counted.
          def exists!(select, count)
            select.target_list.replace(Tree.exists.sub_link.subselect.select_stmt.target_list.to_a)
            return unless count.column

            select.where_clause = Tree.all_of(Tree.conjuncts(select.where_clause) + [not_null(count.column)])
          end

          # A copy of column, IS NOT NULL.
          def not_null(column)
            copy = PgQuery::Node.new(column_ref: PgQuery::ColumnRef.decode(PgQuery::ColumnRef.encode(column)))
            PgQuery::Node.new(null_test: PgQuery::NullTest.new(arg: copy, nulltesttype: :IS_NOT_NULL))
          end

          # The SELECT of a scalar subquery that gives exactly one row,
          # since it has one column and no WITH, DISTINCT, GROUP BY, HAVING,
          # WINDOW, ORDER BY, LIMIT, OFFSET, or locking clause, or nil. A set
          # operation's select list is empty: its arms hold theirs.
          def one_row(link)
            select = link.subselect.select_stmt if link.sub_link_type == :EXPR_SUBLINK
            return unless select && Tree.plain_select?(select)

            select if select.distinct_clause.empty? && select.target_list.size == 1
          end

          # The select list's FuncCall, if it's a count this reads.
          def counted(select)
            call = select.target_list.first.res_target.val.func_call
            call if call && NAMES.include?(call.funcname.map { it.string&.sval }) && plain_call?(call)
          end

          # A WITHIN GROUP's ORDER BY is in agg_order too.
          def plain_call?(call)
            call.agg_filter.nil? && call.over.nil? && call.agg_order.empty? && !call.agg_distinct &&
              call.args.size == (call.agg_star ? 0 : 1)
          end

          # Whether count(ref) counts a column of a table in select's own
          # FROM, whose type isn't a row type. A column of an outer query
          # would make the count that query's aggregate, not the
          # subquery's. IS NOT NULL of a row is true only when every field
          # is not null, but count counts a row of NULLs (see
          # Catalog#row_type?). And name.f may call a function f of the
          # table's row, which may return a row, so ref must be a column the
          # catalog has.
          def column?(select, ref, catalog)
            column = table_column(select.from_clause, ref, catalog)
            !column.nil? && !catalog.column_info(*column).nil? && !catalog.row_type?(*column)
          end

          # [schema, table, column] for ref, written name.column where name
          # is one table of from, or as a bare column exactly one table of
          # from has, when every item of from is one. Each table is a plain
          # table (see Tree.plain_table?), ONLY or not. Otherwise nil.
          def table_column(from, ref, catalog)
            items = Tree.from_items(from)
            name, column = Tree.qualified(ref)
            column ||= Tree.bare_name(ref)
            found = name ? items.select { it.name == name } : having(items, column, catalog)
            table = found.first.table if found.size == 1
            [table.schemaname, table.relname, column] if table && Tree.plain_table?(table, only: true)
          end

          # The items that have the column, which is where Postgres looks for
          # a bare column before an outer query's, or none unless every item
          # is a table, whose columns the catalog knows. Two items with the
          # column would make the query fail.
          def having(items, column, catalog)
            return [] unless column && items.all?(&:table)

            items.select { catalog.column_names(it.table.schemaname, it.table.relname).include?(column) }
          end
        end
      end
    end
  end
end
