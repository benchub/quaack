# frozen_string_literal: true

module Quaack
  module Enclave
    # One node of a parsed EXPLAIN (FORMAT JSON) plan, with its children, for
    # GeneratorTwo. It's private to the enclave namespace. The node's fields
    # hold real literals, so inspect shows only the node type.
    class PlanNode
      SORTS = ["Sort", "Incremental Sort"].freeze

      attr_reader :children

      # Raises ArgumentError, without quoting the plan, if the node or any
      # node under it isn't a Hash, or its Plans isn't a list.
      def initialize(fields)
        raise ArgumentError, "explain has a plan node that isn't an object" unless fields.is_a?(Hash)

        plans = fields.fetch("Plans", [])
        raise ArgumentError, "explain has a Plans entry that isn't a list" unless plans.is_a?(Array)

        @fields = fields
        @children = plans.map { |child| PlanNode.new(child) }.freeze
      end

      def inspect = "#<#{self.class} #{type.inspect}>"

      alias to_s inspect

      def [](key) = @fields[key]

      def type = @fields["Node Type"]

      # The scanned table's name, without its schema. nil unless this node
      # scans a table.
      def relation = string("Relation Name")

      # Only a plan made with VERBOSE has the schema.
      def schema = string("Schema")

      # nil for a node that doesn't scan a table, such as a CTE Scan.
      def alias_name = relation && string("Alias")

      def rows = @fields["Actual Rows"].to_f

      def loops = @fields["Actual Loops"].to_f

      # Rows the Filter and the index recheck removed, per loop.
      def removed = @fields["Rows Removed by Filter"].to_f + @fields["Rows Removed by Index Recheck"].to_f

      # The fraction of the rows read that removed accounts for. It's NaN for
      # a node that read no rows, so it never meets a threshold.
      def removed_fraction = removed / (removed + rows)

      def sort? = SORTS.include?(type)

      def inner = children.find { |c| c["Parent Relationship"] == "Inner" }

      # This node and every node under it, depth first.
      def subtree = [self, *children.flat_map(&:subtree)]

      private

      def string(key) = (@fields[key] if @fields[key].is_a?(String))
    end

    private_constant :PlanNode
  end
end
