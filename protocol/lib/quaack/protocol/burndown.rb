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
    end
  end
end
