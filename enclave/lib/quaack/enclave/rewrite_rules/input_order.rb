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
      # its own, or when any ARRAY subquery has no ORDER BY. min, max, sum,
      # and avg count as order-sensitive here: min and max keep the first of
      # two values that compare equal, and a float sum rounds in its input's
      # order, and Blind can tell which types keep them blind only for the
      # top-level SELECT. It looks at the whole statement, not only the
      # SELECTs that read the changed one, which refuses a little more than
      # it needs to.
      module InputOrder
        module_function

        def sensitive?(tree, catalog)
          Tree.find_all(tree, PgQuery::FuncCall).any? { sensitive_call?(it, catalog) } ||
            Tree.find_all(tree, PgQuery::SubLink).any? { unsorted_array?(it) }
        end

        def unsorted_array?(link)
          link.sub_link_type == :ARRAY_SUBLINK && link.subselect.select_stmt&.sort_clause&.empty?
        end

        def sensitive_call?(call, catalog)
          case SubqueryOrderRemoval::Blind.kind(call, catalog)
          when :always, :ordered then false
          when nil then !SubqueryOrderRemoval::Blind.plain?(call, catalog)
          else true
          end
        end
      end
    end
  end
end
