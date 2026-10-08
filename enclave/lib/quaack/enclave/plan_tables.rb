# frozen_string_literal: true

require_relative "relations"

module Quaack
  module Enclave
    # Qualify's check that the run's plan is the query's (DESIGN.md's
    # input): every table the plan scans must be one the query may scan,
    # Relations::Result#scanned, or it raises Relations::Error with the rule
    # plan_table_mismatch. Intake has already refused a plan of another kind
    # of statement as plan_statement_mismatch (see Intake::Plan).
    #
    # A plan node names its table by "Relation Name", without the schema.
    # Only VERBOSE adds "Schema", so a node without one matches a query
    # table of that name in any schema, and a node with one only the table
    # in that schema.
    #
    # The other direction can't be checked soundly: the planner drops a
    # query table it proves isn't needed, as join removal drops a LEFT
    # JOIN's unique side, a constant-false filter drops every table, and an
    # unreferenced CTE is never planned. So a query table the plan doesn't
    # scan is fine.
    #
    # Views and partitioned tables never get here: Relations refuses them
    # first, so the plan's tables are the query's own, and their
    # inheritance descendants.
    module PlanTables
      RULE = "plan_table_mismatch"

      module_function

      def check!(plan, scanned)
        nodes(plan[0]["Plan"]).each do |node|
          name = node["Relation Name"]
          next unless name.is_a?(String)
          next if scanned.any? { it.name == name && (!node["Schema"].is_a?(String) || it.schema == node["Schema"]) }

          raise Relations::Error.new(RULE, "the plan scans a table the query doesn't read"), cause: nil
        end
        nil
      end

      # The node and every node under it. Intake has checked each Plans is
      # a list of objects.
      def nodes(node) = [node, *node.fetch("Plans", []).flat_map { nodes(it) }]
    end
  end
end
