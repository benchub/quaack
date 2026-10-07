# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of a step_counts message (DESIGN.md's progress lines for
    # `quaack run`): what a step did, as small counts under fixed names, and
    # for rewrite-rules the names of the rules that fired. Never a value,
    # SQL, or anything else a store entry holds.
    #
    #   StepCounts.valid?({ "found" => 12, "used" => 3 })     # => true
    #   StepCounts.valid?({ "rules" => ["or_to_union"] })      # => true
    module StepCounts
      # Each count a step may send. Which steps send which is the enclave's
      # concern; the driver reads only the ones its summary for that step
      # names.
      COUNTS = %w[found used ranked combined tables sets timed_out combinations measured compared survivors
                  discarded partial top excluded].map(&:freeze).freeze

      # The names of the enclave's rewrite rules, the names of
      # Enclave::RewriteRules::RULES in order. An enclave spec checks the
      # two lists match. A rule's name is QUAACK's own constant.
      RULE_NAMES = %w[implied_predicate_removal transitive_predicate_copy shared_scan_cte key_in_self_join
                      or_to_union not_in_to_not_exists existence_in_flip distinct_join_to_exists cte_hoist_dedupe
                      union_outer_filter_removal unused_join_removal polymorphic_key_copy].map(&:freeze).freeze

      # As Burndown's: no real count comes near it.
      MAX_COUNT = 10**12

      module_function

      # Whether fields, as JSON reads them back (String keys), hold only
      # COUNTS, each an Integer from zero up to below MAX_COUNT, and maybe
      # rules, an Array of distinct names from RULE_NAMES. This is the one
      # check on what step_counts may carry, for the enclave's egress
      # function and the driver both.
      def valid?(fields)
        fields.is_a?(Hash) && fields.all? do |key, value|
          key == "rules" ? rules?(value) : COUNTS.include?(key) && count?(value)
        end
      end

      def rules?(names)
        names.is_a?(Array) && names.all? { RULE_NAMES.include?(it) } && names.uniq.size == names.size
      end

      def count?(count) = count.is_a?(Integer) && count >= 0 && count < MAX_COUNT

      private_class_method :rules?, :count?
    end
  end
end
