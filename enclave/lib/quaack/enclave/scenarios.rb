# frozen_string_literal: true

require "pg_query"
require_relative "arena_schema"
require_relative "table_name"
require_relative "value_pools"
require_relative "scenarios/checks"
require_relative "scenarios/nulls"
require_relative "scenarios/reads"
require_relative "scenarios/topology"
require_relative "scenarios/values"

module Quaack
  module Enclave
    # What's left of rewrite-test's scenario fixtures, which task
    # 20261012-4 replaced with the disproof search: the rules a
    # counterexample round's parent rows follow (Counterexamples::ParentRows,
    # Deferral) and the tables a query names, which the search reads too.
    #
    # - Checks: a column's simple CHECKs, and the value one allows.
    # - Values: a column's typical value, by its type (Types, Literals).
    # - Nulls: whether a row may leave a column NULL.
    # - Reads: the columns the queries read.
    # - Topology: the load order, parents first, and the foreign keys in a
    #   cycle it cuts, with their columns deferred.
    #
    # Trust boundary: the values stay in the enclave. Errors name a rule,
    # and for unsupported_type and domain_check the table, column, and
    # type no value can fill, which are schema, never a row value.
    module Scenarios
      class Error < StandardError
        attr_reader :rule, :column, :cycle

        # column is { "table", "column", "type" }, as ErrorFilter sends it.
        # cycle is an fk_cycle's TableNames, in the order their foreign
        # keys point, ending with the first again.
        def initialize(rule, column: nil, cycle: nil)
          @rule = rule
          @column = column
          @cycle = cycle
          super(column ? "#{rule}: #{column["table"]}.#{column["column"]} (#{column["type"]})" : rule.to_s)
        end
      end

      module_function

      # The plain tables a parse names.
      def query_tables(node, found = [])
        if node.is_a?(PgQuery::RangeVar) && !node.schemaname.empty?
          found << TableName.new(schema: node.schemaname, name: node.relname)
        end
        ValuePools::Sides.children(node).each { |c| query_tables(c, found) }
        found.uniq
      end
    end
  end
end
