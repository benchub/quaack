# frozen_string_literal: true

module Quaack
  module Enclave
    class CLI
      # A call the CLI refuses before any step runs: bad argv, a bad run
      # ID, or bad stdin. The CLI sends it as an error line with its rule
      # and exits EX_USAGE. Its message names only the rule, and it's raised
      # with no cause, so nothing from argv or stdin rides along.
      class Refused < StandardError
        attr_reader :rule

        def initialize(rule)
          @rule = rule
          super("refused: #{rule}")
        end
      end
    end
  end
end
