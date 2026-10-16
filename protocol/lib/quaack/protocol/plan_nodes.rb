# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of a plan in DESIGN.md's report: the report message's
    # original_plan and each rewrite's plan. A plan is an Array of nodes,
    # depth first, and each node carries exactly FIELDS: its type, relation
    # ("schema.name") and index name, its estimated and actual rows, its
    # selectivity, its depth, which the enclave counts from 0 for the top
    # node, and its shared hit and read block counts, as EXPLAIN (ANALYZE,
    # BUFFERS) gives them, each including the node's children, and its
    # actual total time in milliseconds and actual loops, as EXPLAIN
    # ANALYZE gives them: the time per loop, the node's children included.
    # These are the plan's shape and cost, never data. Never a condition,
    # an alias, or any other field of the plan.
    module PlanNodes
      BLOCKS = %w[shared_hit_blocks shared_read_blocks].map(&:freeze).freeze
      TIMING = %w[actual_total_time actual_loops].map(&:freeze).freeze
      FIELDS = [*%w[node relation index est_rows actual_rows selectivity depth].map(&:freeze), *BLOCKS,
                *TIMING].freeze

      module_function

      # Whether plan is an Array of nodes, as JSON reads them back, each a
      # Hash with exactly FIELDS as String keys: a String type, a String or
      # nil relation and index, an Integer, Float, or nil for each row count
      # and the selectivity, an Integer depth of zero or more, and an Integer
      # of zero or more or nil for each block count, and a finite Integer or
      # Float of zero or more or nil for the time and loops. This is
      # the one check on what a report's plan may carry, for the enclave's
      # egress function and the driver both.
      def valid?(plan) = plan.is_a?(Array) && plan.all? { node?(it) }

      def node?(node) = node.is_a?(Hash) && node.keys.all?(String) && node.keys.sort == FIELDS.sort && values?(node)

      def values?(node)
        node["node"].is_a?(String) && %w[relation index].all? { name?(node[it]) } &&
          %w[est_rows actual_rows selectivity].all? { number?(node[it]) } &&
          count?(node["depth"]) && counts?(node)
      end

      def counts?(node)
        BLOCKS.all? { node[it].nil? || count?(node[it]) } && TIMING.all? { optional_measure?(node[it]) }
      end

      def optional_measure?(value) = value.nil? || measure?(value)

      def measure?(value) = (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && !value.negative?

      def count?(count) = count.is_a?(Integer) && !count.negative?

      def name?(name) = name.nil? || name.is_a?(String)

      def number?(number) = number.nil? || number.is_a?(Integer) || number.is_a?(Float)

      private_class_method :node?, :values?, :counts?, :name?, :number?, :count?, :measure?, :optional_measure?
    end
  end
end
