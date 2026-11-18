# frozen_string_literal: true

require_relative "tree"
require_relative "../constant_value"

module Quaack
  module Enclave
    module Fuzz
      # The integer a count is compared with (task 20261113-210241-1), for
      # Facts#counted: count(*) or count(x) with no window or DISTINCT, or
      # a scalar subquery whose one target is such a count, with no GROUP
      # BY, compared with an integer constant (or a $n bound to one).
      #
      #   Counted.threshold(count_node, const_node, nil)  # => 7
      #
      # Trust boundary: the queries' constants, so they stay in the enclave.
      module Counted
        module_function

        def threshold(node, other, binding)
          return unless count?(node) || subquery?(node)

          const = constant(other, binding)
          Integer(Tree.value(const).to_s, exception: false) if const && !const[:isnull]
        end

        def constant(node, binding)
          return unless node

          node[:a_const] || (node.key?(:param_ref) && ConstantValue.from_hash(node, binding)) || nil
        end

        def count?(node)
          call = node&.dig(:func_call) or return false
          plain?(call) && name(call) == "count" && (call[:agg_star] || call[:args]&.size == 1)
        end

        def plain?(call) = !call[:over] && !call[:agg_distinct]

        def name(call) = call[:funcname]&.last&.dig(:string, :sval)

        def subquery?(node)
          select = scalar(node) or return false
          targets = select[:target_list] || []
          !select[:group_clause] && targets.size == 1 && count?(targets.first.dig(:res_target, :val))
        end

        # A scalar subquery's SELECT, or nil.
        def scalar(node)
          link = node&.dig(:sub_link)
          link.dig(:subselect, :select_stmt) if link && link[:sub_link_type] == :EXPR_SUBLINK
        end
      end
    end
  end
end
