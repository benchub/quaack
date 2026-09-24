# frozen_string_literal: true

module Quaack
  module Enclave
    module Intake
      # An operator input intake refuses. The CLI sends it as an error line
      # with only its rule (see ErrorFilter). Its message is the rule alone,
      # and it's always raised with no cause, since the inputs hold
      # production literals.
      class Error < StandardError
        attr_reader :rule

        def initialize(rule)
          @rule = rule
          super
        end
      end
    end
  end
end
