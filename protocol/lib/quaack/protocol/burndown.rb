# frozen_string_literal: true

module Quaack
  module Protocol
    # The names both sides use for DESIGN.md's burndown. The enclave
    # script records each stage's counts under a stage from STAGES, and the
    # driver counts its LLM calls under a step from LLM_STEPS. Every other
    # name in a burndown, such as a drop reason, a source, a search, or a
    # work total, must match NAME.
    module Burndown
      # One per row of DESIGN.md's burndown tables. index-dedupe through index-rank also key
      # the index searches of plan-pruning and rewrite-index-ideas, one search per rewrite.
      STAGES = %w[index-from-query index-from-plan index-dedupe index-test llm-index-ideas llm-index-refine
                  index-rank rewrite-rules llm-rewrites assumption-check operator-rewrites plan-pruning
                  rewrite-test counterexamples rewrite-index-ideas measurement].map(&:freeze).freeze

      # The steps the driver runs that call an LLM (DESIGN.md, "Which part runs
      # each step"). The last two are llm-index-ideas and llm-index-refine in rewrite-index-ideas, searching
      # for a rewrite.
      LLM_STEPS = %w[llm-index-ideas llm-index-refine llm-rewrites operator-rewrites llm-counterexamples
                     rewrite-llm-index-ideas rewrite-llm-index-refine].map(&:freeze).freeze

      # A lowercase word, such as duplicate or generator_one.
      NAME = /\A[a-z][a-z0-9_]{0,62}\z/

      # A stage record's fields. The first three are counts. The rest break
      # a count down by name: added by source, dropped by reason, and extra
      # for counts that don't move items, which aren't summed.
      COUNTS = %w[in set_aside out].freeze
      BREAKDOWNS = %w[added dropped extra].freeze
      FIELDS = %w[in added dropped set_aside out extra].freeze

      # No real count comes near this, so a larger Integer, such as a
      # production value passed in by mistake, is refused.
      MAX_COUNT = 10**12

      module_function

      # Whether stages and totals are a whole burndown, as JSON reads it
      # back: stages maps each of STAGES to its searches, and each search to
      # a record with exactly FIELDS. totals maps each work total to its
      # count. Every name is a String matching NAME, every count an Integer
      # from zero up to below MAX_COUNT, and every record adds up (see
      # adds_up?). This is the one check on what a burndown may carry, for the enclave's store and
      # its egress function both.
      def valid?(stages:, totals:)
        counts?(totals) && stages.is_a?(Hash) &&
          stages.all? { |stage, searches| STAGES.include?(stage) && names?(searches) { record?(it) } }
      end

      # Whether a record's in + added - dropped - set_aside equals its out.
      def adds_up?(record)
        came = record["in"] + record["added"].values.sum
        came - record["dropped"].values.sum - record["set_aside"] == record["out"]
      end

      def record?(record)
        record.is_a?(Hash) && record.keys.all?(String) && record.keys.sort == FIELDS.sort &&
          COUNTS.all? { count?(record[it]) } && BREAKDOWNS.all? { counts?(record[it]) } && adds_up?(record)
      end

      def counts?(hash) = names?(hash) { count?(it) }

      # Whether hash is a Hash whose keys are Strings matching NAME and whose
      # values pass the block.
      def names?(hash)
        hash.is_a?(Hash) && hash.all? { |name, value| name.is_a?(String) && NAME.match?(name) && yield(value) }
      end

      def count?(count) = count.is_a?(Integer) && count >= 0 && count < MAX_COUNT

      private_class_method :record?, :counts?, :names?, :count?
    end
  end
end
