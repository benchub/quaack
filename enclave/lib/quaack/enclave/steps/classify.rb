# frozen_string_literal: true

require_relative "../config"
require_relative "../pii_classification"

module Quaack
  module Enclave
    module Steps
      # `quaacks classify --run <run ID>` (README 3f): classifies each column
      # of the query's tables as PII or not and as low-cardinality or not
      # (see PiiClassification), and sends the statistics that may leave.
      #
      # It reads the quaacks config (pii_columns, cardinality_threshold)
      # first, so a bad one fails before anything else, then the run's
      # statistics entry, which `quaacks statistics` wrote. It doesn't touch
      # production. It writes one entry, classification (see
      # PiiClassification for its form), for Dedupe (5a-3). A failure stores
      # nothing: the entry is written once, atomically, after everything it
      # needs has been read and classified.
      #
      # It returns one column_stats message per column, tables in the
      # statistics entry's order and columns in attnum order, before DONE.
      # Each is a projection of the entry's outbound_statistics, nothing more:
      # - table: {"schema", "name"}, and column: its name. Both are schema.
      # - n_distinct, null_frac, correlation: for every column.
      # - mcv_freqs: the MCV frequencies, nil for a PII column.
      # - low_card_values: the MCV values, nil unless the column is
      #   low-cardinality. They're the only real values 3f lets out.
      module Classify
        module_function

        def call(store:, **)
          config = Config.load
          messages(PiiClassification.run(store:, config:).outbound_statistics)
        end

        def messages(outbound)
          outbound["tables"].flat_map do |table|
            name = { "schema" => table["schema"], "name" => table["name"] }
            table["columns"].map { message(name, it) }
          end
        end

        def message(table, column)
          { type: :column_stats, table:, column: column["name"], n_distinct: column["n_distinct"],
            null_frac: column["null_frac"], correlation: column["correlation"],
            mcv_freqs: column["most_common_freqs"], low_card_values: column["most_common_vals"] }
        end
      end
    end
  end
end
