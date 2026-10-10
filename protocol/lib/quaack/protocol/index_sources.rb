# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of the report's index_sources (DESIGN.md's report): for each
    # of QUAACK's index sources, how many of the indexes it built that
    # source proposed, how many of those were not better, and how many were
    # ranked, and how many of its proposals index-dedupe dropped as already
    # existing (existed) and index-test dropped as never used, refused by
    # HypoPG, or unrenderable (ignored), once per search, as the burndown
    # counts them. An index more than one source proposed counts under each of
    # them. Only counts, under names from these fixed lists, never an index
    # name, DDL, or anything else a store entry holds.
    module IndexSources
      # Generator one (index-from-query), generator two (index-from-plan),
      # and the LLM's rounds, as the burndown names what each added.
      SOURCES = %w[generator_one generator_two llm].map(&:freeze).freeze
      COLUMNS = %w[built not_better ranked existed ignored].map(&:freeze).freeze

      # What an entry of the report's indexes may hold: the index's redacted
      # DDL, its size, the existing index covering it, and the names of its sources.
      ENTRY_KEYS = %w[ddl size covered_by sources].map(&:freeze).freeze

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

      # The report's indexes entries: a Hash, by built index name, of Hashes
      # with only ENTRY_KEYS, whose sources, if it has them, are each a name
      # from SOURCES once, so the report can say who proposed each index. An
      # entry with no sources is an older enclave's, which the report says
      # isn't recorded.
      def entries_valid?(indexes)
        indexes.is_a?(Hash) && indexes.values.all? { entry?(it) }
      end

      def entry?(entry)
        entry.is_a?(Hash) && (entry.keys - ENTRY_KEYS).empty? && entry.fetch("sources", []).then do |sources|
          sources.is_a?(Array) && sources.all? { SOURCES.include?(it) } && sources.uniq == sources
        end
      end

      def count?(count) = count.is_a?(Integer) && count >= 0 && count < MAX_COUNT

      private_class_method :counts?, :count?, :entry?
    end
  end
end
