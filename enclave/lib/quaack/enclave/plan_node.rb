# frozen_string_literal: true

module Quaack
  module Enclave
    # One node of a parsed EXPLAIN (FORMAT JSON) plan, with its children, for
    # GeneratorTwo. It's private to the enclave namespace. The node's fields
    # hold real literals, so inspect shows only the node type.
    class PlanNode
      SORTS = ["Sort", "Incremental Sort"].freeze

      # The counts the patterns read. A node that doesn't print one reads 0.
      NUMBERS = ["Actual Rows", "Actual Loops", "Rows Removed by Filter", "Rows Removed by Index Recheck",
                 "Hash Batches"].freeze

      attr_reader :children

      # Raises ArgumentError, without quoting the plan, if the node or any
      # node under it isn't a Hash, its Plans isn't a list, or one of its
      # NUMBERS isn't a number.
      def initialize(fields)
        raise ArgumentError, "explain has a plan node that isn't an object" unless fields.is_a?(Hash)

        plans = fields.fetch("Plans", [])
        raise ArgumentError, "explain has a Plans entry that isn't a list" unless plans.is_a?(Array)

        @fields = fields
        @numbers = NUMBERS.to_h { |key| [key, read_number(key)] }.freeze
        @children = plans.map { |child| PlanNode.new(child) }.freeze
      end

      # to_s needs nothing: Object#to_s never shows instance variables.
      def inspect = "#<#{self.class} #{type.inspect}>"

      def [](key) = @fields[key]

      def type = @fields["Node Type"]

      # The scanned table's name, without its schema. nil unless this node
      # scans a table.
      def relation = string("Relation Name")

      # Only a plan made with VERBOSE has the schema.
      def schema = string("Schema")

      # A CTE Scan or Subquery Scan has one too. Its columns map to no table.
      def alias_name = string("Alias")

      def rows = number("Actual Rows")

      def loops = number("Actual Loops")

      # Rows the Filter and the index recheck removed, per loop.
      def removed = number("Rows Removed by Filter") + number("Rows Removed by Index Recheck")

      def hash_batches = number("Hash Batches")

      # The fraction of the rows read that removed accounts for. It's NaN for
      # a node that read no rows, so it never meets a threshold.
      def removed_fraction = removed / (removed + rows)

      def sort? = SORTS.include?(type)

      def parallel? = @fields["Parallel Aware"] == true

      def inner = children.find { |c| c["Parent Relationship"] == "Inner" }

      # This node and every node under it, depth first.
      def subtree = [self, *children.flat_map(&:subtree)]

      private

      def string(key) = (@fields[key] if @fields[key].is_a?(String))

      def number(key) = @numbers.fetch(key)

      # The message names the field, never its value.
      def read_number(key)
        value = @fields.fetch(key, 0)
        return value.to_f if value.is_a?(Numeric)

        raise ArgumentError, "explain has a #{key} that isn't a number"
      end
    end

    private_constant :PlanNode
  end
end
