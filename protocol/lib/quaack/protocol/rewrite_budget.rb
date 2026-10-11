# frozen_string_literal: true

module Quaack
  module Protocol
    # rewrite-test's wall-clock budget per rewrite (DESIGN.md, rewrite-test;
    # task 20261010-53). A rewrite whose test runs longer than SECONDS is
    # stopped and left out, untested: its rewrite_test message's rule is
    # RULE, its report fate FATE, and its burndown drop reason RULE. It's
    # never called wrong.
    #
    # A rewrite_test message's rule must be nil or a lowercase word, one of
    # the enclave's rule constants (rule?), so no error text rides out in
    # it. Egress and the driver both check it.
    #
    #   RewriteBudget.rule?("out_of_time")  # => true
    module RewriteBudget
      SECONDS = 300
      RULE = "out_of_time"
      FATE = "rewrite_test_out_of_time"

      WORD = /\A[a-z][a-z0-9_]{0,62}\z/

      module_function

      def rule?(rule) = rule.nil? || (rule.is_a?(String) && WORD.match?(rule))

      # The budget in whole minutes, for the driver's words.
      def minutes = SECONDS / 60
    end
  end
end
