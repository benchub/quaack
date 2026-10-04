# frozen_string_literal: true

require_relative "../inventory/production"
require_relative "../planner_statistics"
require_relative "../table_name"

module Quaack
  module Enclave
    module Steps
      # `quaacks statistics --run <run ID>` (DESIGN.md's statistics): the planner
      # statistics, existing indexes, and extended statistics for the
      # query's tables (see Enclave::PlannerStatistics).
      #
      # It reads the run's server and relations entries, the latter written
      # by `quaacks qualify`: the query's own tables, not schema-dump's subset, whose
      # FK parents no generator reads statistics for. It connects to the
      # server as inventory does (Inventory::Production.connect), and
      # PlannerStatistics.run reads everything inside one
      # Production.read_only transaction.
      #
      # It writes one entry, statistics (see PlannerStatistics for its
      # form), for generators one and two (index-from-query, index-from-plan), Dedupe (index-dedupe), and
      # classify. PlannerStatistics.load rebuilds the Statistics from it. The
      # entry holds MCV lists, histogram bounds, and partial-index
      # predicates, all value-class, so nothing of it is sent.
      #
      # PlannerStatistics.run writes only after the transaction has closed,
      # so a failed read or ROLLBACK stores nothing. Its only line is DONE.
      # A refusal names only its rule.
      module Statistics
        module_function

        def call(store:, **)
          host = store.read("server")
          relations = store.read("relations").map { TableName.new(schema: it["schema"], name: it["name"]) }
          connection = Enclave::Inventory::Production.connect(host)
          PlannerStatistics.run(store:, relations:, connection:)
          []
        ensure
          connection&.close
        end
      end
    end
  end
end
