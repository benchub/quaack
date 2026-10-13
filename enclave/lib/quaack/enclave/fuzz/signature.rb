# frozen_string_literal: true

require "json"

module Quaack
  module Enclave
    module Fuzz
      # A fuzz trial's coverage signature (task 20261012-2): what the trial
      # made the two plans do, from EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF,
      # FORMAT JSON) of each query. StopRule counts a signature it hasn't
      # seen as new coverage.
      #
      #   Signature.trial(original_json, candidate_json)
      #   # => [[["Hash Join", :many, false], ["Seq Scan", 1, true]], :error]
      #
      # Each node, depth first, is its type, its actual rows over all its
      # loops as 0, 1, or :many (PG 18's Actual Rows is an average per loop,
      # so it can be fractional), and whether a filter or join filter
      # removed any rows. A query that errored is :error.
      #
      # Trust boundary. EXPLAIN's text holds literal values (a Filter, an
      # Index Cond), so a signature keeps only node types, which are
      # Postgres's own words, counts bucketed, and booleans. It never leaves
      # the enclave either: only the stop rule reads it.
      module Signature
        REMOVED = ["Rows Removed by Filter", "Rows Removed by Join Filter"].freeze

        module_function

        def trial(original, candidate) = [plan(original), plan(candidate)]

        # json is EXPLAIN's output, or nil for a query that errored.
        def plan(json)
          return :error if json.nil?

          nodes(JSON.parse(json).first.fetch("Plan"))
        end

        def nodes(node, found = [])
          found << [node.fetch("Node Type"), rows(node), REMOVED.any? { node.fetch(it, 0).positive? }]
          node.fetch("Plans", []).each { nodes(it, found) }
          found
        end

        def rows(node)
          total = node.fetch("Actual Rows", 0) * node.fetch("Actual Loops", 0)
          return 0 if total.zero?

          total <= 1 ? 1 : :many
        end
      end
    end
  end
end
