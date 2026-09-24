# frozen_string_literal: true

require "quaack/protocol/burndown"

module Quaack
  module Driver
    # The driver's side of the README 15b burndown: how many LLM calls each
    # step made. The enclave script records its own counts in the governed
    # store. These stay in memory for the run, and the report reads them.
    #
    #   burndown = Burndown.new
    #   burndown.llm_call("5a-5")   # the LLM client calls this once per call
    #   burndown.llm_calls          # => { "5a-5" => 1 }
    #
    # A step is one of Protocol::Burndown::LLM_STEPS, the steps the driver
    # runs that call an LLM.
    class Burndown
      def initialize
        @llm_calls = {}
      end

      # Counts one LLM call made for step.
      def llm_call(step)
        steps = Protocol::Burndown::LLM_STEPS
        index = steps.index(step)
        raise ArgumentError, "step must be a step that calls an LLM, one of #{steps.join(", ")}" unless index

        # Counted under the protocol's own String, never the caller's.
        step = steps[index]
        @llm_calls[step] = @llm_calls.fetch(step, 0) + 1
        nil
      end

      # Each step's LLM calls so far, in the order each step first called.
      def llm_calls = @llm_calls.dup.freeze
    end
  end
end
