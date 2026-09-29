# frozen_string_literal: true

require_relative "../config"
require_relative "../pii_classification"

module Quaack
  module Enclave
    module Steps
      # `quaacks classify --run <run ID>` (DESIGN.md 3f): classifies each column
      # of the query's tables as PII or not and as low-cardinality or not
      # (see PiiClassification), and stores the statistics that may leave.
      #
      # It reads the quaacks config (pii_columns, cardinality_threshold)
      # first, so a bad one fails before anything else, then the run's
      # statistics entry, which `quaacks statistics` wrote. It doesn't touch
      # production. It writes one entry, classification (see
      # PiiClassification for its form): the columns, for Dedupe (5a-3), and
      # outbound_statistics, which the 5a-5 payload step sends, so data
      # leaves only when the LLM needs it. A failure stores nothing: the
      # entry is written once, atomically, at the end.
      #
      # It sends nothing itself. Its only line is DONE.
      module Classify
        module_function

        def call(store:, **)
          PiiClassification.run(store:, config: Config.load)
          []
        end
      end
    end
  end
end
