# frozen_string_literal: true

module Quaack
  module Enclave
    module Intake
      # An operator input intake refuses. The CLI sends it as an error line
      # with only its rule, and for query_unreadable or plan_unreadable one
      # fixed reason (see ErrorFilter). Its message is the rule alone, and
      # it's always raised with no cause, since the inputs hold production
      # literals.
      class Error < StandardError
        attr_reader :rule, :reason

        def initialize(rule, reason: nil)
          @rule = rule
          @reason = reason
          super(rule)
        end
      end
    end
  end
end
