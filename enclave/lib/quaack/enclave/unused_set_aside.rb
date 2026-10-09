# frozen_string_literal: true

module Quaack
  module Enclave
    # The candidates index-test found unused that index-build builds for real anyway
    # (20260927-11): a non-unique, non-partial B-tree with no INCLUDE whose
    # leading key is a bare column classify classes as low-cardinality. B-tree
    # deduplication makes such an index far smaller than HypoPG estimates,
    # so the planner may well use the real one.
    #
    #   UnusedSetAside.select(report, low_cardinality)  # => [IndexCandidate]
    #
    # report is a SingleCandidateTest report, and low_cardinality is
    # PiiClassification#low_cardinality's [TableName, column] pairs.
    #
    # Each one is a real build, so a search sets aside at most
    # MAX_PER_SEARCH, the first in the report's order (20260927-19).
    module UnusedSetAside
      MAX_PER_SEARCH = 2

      module_function

      def select(report, low_cardinality)
        report.results.reject { it.used? || it.refusal }.map(&:candidate)
              .select { eligible?(it, low_cardinality) }.first(MAX_PER_SEARCH)
      end

      def eligible?(candidate, low_cardinality)
        key_only_btree?(candidate) && low_cardinality_lead?(candidate, low_cardinality)
      end

      def key_only_btree?(candidate)
        candidate.access_method == :btree && candidate.include.empty? && candidate.predicate.nil? && !candidate.unique
      end

      def low_cardinality_lead?(candidate, low_cardinality)
        lead = candidate.key.first
        lead.expression.nil? && low_cardinality.include?([candidate.table, lead.name])
      end
    end
  end
end
