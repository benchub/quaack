# frozen_string_literal: true

require "pg_query"
require_relative "tree"
require_relative "subquery_order_removal/blind"

module Quaack
  module Enclave
    module RewriteRules
      # Whether a statement could give another result if some SELECT in it
      # gave its rows in another order, beyond what SQL leaves open.
      #
      # A rule that removes a DISTINCT or a join changes the plan, and so
      # the order rows come in. That's fine where nothing reads the order.
      # But an aggregate such as string_agg(t.name, ',') or array_agg(t.id)
      # with no ORDER BY of its own, a window function, and ARRAY(SELECT
      # ...) with no ORDER BY each give their result in the order their
      # rows reach them, so a rewrite under or beside one can give another
      # result (20261018-22).
      #
      # InputOrder.sensitive? holds when any call in the statement, at any
      # depth, is a window function or an aggregate other than the ones
      # SubqueryOrderRemoval::Blind counts as never following their input
      # order (its :always kind, such as count) or that has an ORDER BY of
      # its own, or when any ARRAY subquery has no ORDER BY.
      #
      # min and max keep the first of two values that compare equal, and a
      # float sum rounds in its input order. So min, max, and sum are fine
      # only on a column whose type is an integer, a date, or a timestamp
      # (SAME), and avg only on an integer column (INTEGERS). The column
      # must be one plain column, name.column or a bare column with one
      # FROM item, of a plain table in the FROM of the SELECT whose select
      # list, HAVING, or ORDER BY calls it. Any other argument, or one whose
      # type the catalog can't give, counts as order-sensitive.
      #
      # It looks at the whole statement, not only the SELECTs that read the
      # changed one, which refuses a little more than it needs to.
      module InputOrder
        INTEGERS = %w[smallint integer bigint].freeze
        SAME = [*INTEGERS, "date", "timestamp without time zone", "timestamp with time zone"].freeze

        module_function

        def sensitive?(tree, catalog)
          owners = owners(tree)
          Tree.find_all(tree, PgQuery::FuncCall).any? { sensitive_call?(it, owners[it], catalog) } ||
            Tree.find_all(tree, PgQuery::SubLink).any? { unsorted_array?(it) }
        end

        def unsorted_array?(link)
          link.sub_link_type == :ARRAY_SUBLINK && link.subselect.select_stmt&.sort_clause&.empty?
        end

        def sensitive_call?(call, owner, catalog)
          case SubqueryOrderRemoval::Blind.kind(call, catalog)
          when :always, :ordered then false
          when nil then !SubqueryOrderRemoval::Blind.plain?(call, catalog)
          when :same, :exact then !exact?(call, owner, catalog)
          else true
          end
        end

        # Each call in a SELECT's select list, HAVING, and ORDER BY, not
        # under a subquery of it, by identity, with that SELECT.
        def owners(tree)
          Tree.find_all(tree, PgQuery::SelectStmt).each_with_object({}.compare_by_identity) do |select, owners|
            [select.target_list, select.having_clause, select.sort_clause].each do |clause|
              SubqueryOrderRemoval::Blind.calls(clause, false, []).each do |call, nested|
                owners[call] = select unless nested
              end
            end
          end
        end

        # Whether call is min, max, or sum of a column of a SAME type, or
        # avg of an integer column.
        def exact?(call, owner, catalog)
          return false unless owner && call.args.size == 1

          type = column_type(call.args.first, owner, catalog)
          (SubqueryOrderRemoval::Blind.names(call).last == "avg" ? INTEGERS : SAME).include?(type)
        end

        # The base type of a plain column of a plain table in owner's FROM,
        # or nil.
        def column_type(node, owner, catalog)
          fields = node.column_ref&.fields&.map { it.string&.sval }
          return unless fields&.all? && [1, 2].include?(fields.size)

          items = Tree.from_items(owner.from_clause)
          named = fields.size == 2 ? items.select { it.name == fields.first } : items
          table = named.first.table if named.size == 1
          return unless table && Tree.plain_table?(table)

          catalog.column_info(table.schemaname, table.relname, fields.last)&.base_type
        end
      end
    end
  end
end
