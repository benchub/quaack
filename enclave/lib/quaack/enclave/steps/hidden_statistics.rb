# frozen_string_literal: true

module Quaack
  module Enclave
    module Steps
      # ReportPayload's hidden_statistics (DESIGN.md's statistics and
      # report): the statistics the production role couldn't see, from each
      # table's statistics_hidden (PlannerStatistics).
      #
      #   HiddenStatistics.call(store)
      #   # => { "indexes" => ["customers_lower_email_idx"], "extended_statistics" => 1 }
      #
      # Trust boundary. An index name goes out only if it's one of the
      # table's stored indexes, so it's schema, as ExistingIndexes' are. The
      # extended statistics objects go out only as a count, since the report
      # names none. Egress checks the shape (Protocol::HiddenStatistics). An
      # entry stored before statistics_hidden existed hides nothing.
      module HiddenStatistics
        module_function

        def call(store)
          tables = store.read("statistics")["tables"]
          { "indexes" => tables.flat_map { indexes(it) }.uniq,
            "extended_statistics" => tables.sum { Array(it.dig("statistics_hidden", "extended_statistics")).size } }
        end

        def indexes(table)
          known = table["indexes"].map { it["name"] }
          Array(table.dig("statistics_hidden", "indexes")).select { known.include?(it) }
        end
      end
    end
  end
end
