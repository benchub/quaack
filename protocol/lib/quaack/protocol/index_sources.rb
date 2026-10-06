# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of the report's index_sources (DESIGN.md's report): for each
    # of QUAACK's index sources, how many of the indexes it built that
    # source proposed, how many of those were not better, and how many were
    # ranked. An index more than one source proposed counts under each of
    # them. Only counts, under names from these fixed lists, never an index
    # name, DDL, or anything else a store entry holds.
    module IndexSources
      # Generator one (index-from-query), generator two (index-from-plan),
      # and the LLM's rounds, as the burndown names what each added.
      SOURCES = %w[generator_one generator_two llm].map(&:freeze).freeze
      COLUMNS = %w[built not_better ranked].map(&:freeze).freeze

      # As Burndown's: no real count comes near it.
      MAX_COUNT = 10**12

      module_function

      # Whether field, as JSON reads it back, maps exactly SOURCES, as
      # Strings, to a Hash of exactly COLUMNS, each an Integer from zero up
      # to below MAX_COUNT, with no more not better or
      # ranked than built. This is the one check on what index_sources may
      # carry, for the enclave's egress function and the driver both.
      def valid?(field)
        field.is_a?(Hash) && field.keys.all?(String) && field.keys.sort == SOURCES.sort &&
          field.values.all? { counts?(it) }
      end

      def counts?(counts)
        counts.is_a?(Hash) && counts.keys.all?(String) && counts.keys.sort == COLUMNS.sort &&
          counts.values.all? { count?(it) } && counts.values_at("not_better", "ranked").all? { it <= counts["built"] }
      end

      def count?(count) = count.is_a?(Integer) && count >= 0 && count < MAX_COUNT

      private_class_method :counts?, :count?
    end
  end
end
