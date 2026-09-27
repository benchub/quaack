# frozen_string_literal: true

module Quaack
  module Protocol
    # The names both sides use for the README 15b burndown. The enclave
    # script records each stage's counts under a stage from STAGES, and the
    # driver counts its LLM calls under a step from LLM_STEPS. Every other
    # name in a burndown, such as a drop reason, a source, a search, or a
    # work total, must match NAME.
    module Burndown
      # One per row of the README 15b tables. 5a-3 through 5a-7 also key
      # the index searches of steps 8 and 11, one search per rewrite.
      STAGES = %w[5a-1 5a-2 5a-3 5a-4 5a-5 5a-6 5a-7 6a 6b
                  step7 step8 step9 step10 step11 step14].map(&:freeze).freeze

      # The steps the driver runs that call an LLM (README, "Which part runs
      # each step"). step11 is generator three inside step 11.
      LLM_STEPS = %w[5a-5 5a-6 6a step7 10a step11].map(&:freeze).freeze

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
