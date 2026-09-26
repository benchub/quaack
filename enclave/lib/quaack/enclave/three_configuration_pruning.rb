# frozen_string_literal: true

require_relative "single_candidate_test"

module Quaack
  module Enclave
    # README step 8's three-configuration pruning: whether a rewrite
    # candidate can't run any differently from the original, so step 8
    # discards it.
    #
    #   ThreeConfigurationPruning.discard?(connection, original: sql, rewrite: sql,
    #                                      literal_sets: { slow: ["open"] },
    #                                      top: { original: [IndexCandidate, ...], rewrite: [...] })
    #   # => true or false
    #
    # connection, literal_sets, and the queries are as SingleCandidateTest
    # takes them. top[:original] is the original's top three indexes from
    # 5a-7 (IndexRanking's top, as candidates), and top[:rewrite] the
    # rewrite's own top three mechanical indexes, ranked the same way.
    #
    # Both queries are planned with EXPLAIN in three configurations: no
    # hypothetical indexes, top[:original]'s all at once, and
    # top[:rewrite]'s all at once. In each one, the rewrite's canonical
    # plan is compared with the original's under the same configuration,
    # for every literal set.
    # It returns true only when every one of those matches. If HypoPG
    # refuses an index, that configuration can't be compared, so it counts
    # as a difference and the rewrite is kept.
    #
    # The planning runs in SingleCandidateTest sessions, so it has 5a-4's
    # transaction, settings, fresh prepares, and cleanup, and its errors.
    # The result is a Boolean, so nothing from the plans or literals leaves.
    module ThreeConfigurationPruning
      module_function

      def discard?(connection, original:, rewrite:, literal_sets:, top:)
        configurations = [[], top.fetch(:original), top.fetch(:rewrite)]
        original_plans = plans(connection, original, literal_sets, configurations)
        rewrite_plans = plans(connection, rewrite, literal_sets, configurations)
        original_plans.zip(rewrite_plans).all? { |a, b| same?(a, b) }
      end

      # One Measurement per configuration.
      def plans(connection, query, literal_sets, configurations)
        SingleCandidateTest.session(connection, query:, literal_sets:) do |session|
          configurations.map { session.measure(it) }
        end
      end

      def same?(original, rewrite)
        return false if original.refusal || rewrite.refusal

        original.plans.all? { |set, plan| plan.canonical_plan.matches?(rewrite.plans.fetch(set).canonical_plan) }
      end
    end
  end
end
