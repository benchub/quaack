# frozen_string_literal: true

module Quaack
  module Enclave
    # The candidates 5a-4 found unused that 12a builds for real anyway
    # (20260927-11): a non-unique, non-partial B-tree with no INCLUDE whose
    # leading key is a bare column 3f classes as low-cardinality. B-tree
    # deduplication makes such an index far smaller than HypoPG estimates,
    # so the planner may well use the real one.
    #
    #   UnusedSetAside.select(report, low_cardinality)  # => [IndexCandidate]
    #
    # report is a SingleCandidateTest report, and low_cardinality is
    # PiiClassification#low_cardinality's [TableName, column] pairs.
    module UnusedSetAside
      module_function

      def select(report, low_cardinality)
        report.results.reject { it.used? || it.refusal }.map(&:candidate).select { eligible?(it, low_cardinality) }
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
