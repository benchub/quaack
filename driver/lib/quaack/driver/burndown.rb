# frozen_string_literal: true

require "quaack/protocol/burndown"

module Quaack
  module Driver
    # The driver's side of DESIGN.md's burndown: how many LLM calls each
    # step made. The enclave script records its own counts in the governed
    # store. These stay in memory for the run, and the report reads them.
    #
    #   burndown = Burndown.new
    #   burndown.llm_call("llm-index-ideas")   # the LLM client calls this once per call
    #   burndown.llm_calls          # => { "llm-index-ideas" => 1 }
    #
    # A step is one of Protocol::Burndown::LLM_STEPS, the steps the driver
    # runs that call an LLM. A call may also name the provider that made it,
    # an entry's name from the llms list (DESIGN.md's Accounting), and is
    # then counted under that provider too.
    #
    #   burndown.llm_call("llm-rewrites", "groq")
    #   burndown.llm_calls_by_provider   # => { "groq" => { "llm-rewrites" => 1 } }
    class Burndown
      # One Burndown that holds every count of burndowns, added up.
      def self.sum(burndowns) = new.tap { |sum| burndowns.each { sum.add_all(it) } }

      def initialize
        @llm_calls = {}
        @by_provider = {}
      end

      # Counts one LLM call made for step, by provider, if given.
      def llm_call(step, provider = nil)
        steps = Protocol::Burndown::LLM_STEPS
        index = steps.index(step)
        raise ArgumentError, "step must be a step that calls an LLM, one of #{steps.join(", ")}" unless index

        # Counted under the protocol's own String, never the caller's.
        add(steps[index], provider, 1)
        nil
      end

      # Each step's LLM calls so far, in the order each step first called.
      def llm_calls = @llm_calls.dup.freeze

      # Each provider's LLM calls so far, by step, in the order each
      # provider, and then each of its steps, first called.
      def llm_calls_by_provider = @by_provider.transform_values { it.dup.freeze }.freeze

      # Adds every count of other to this one's.
      def add_all(other)
        other.llm_calls.each { |step, count| add(step, nil, count) }
        other.llm_calls_by_provider.each { |name, calls| calls.each { |step, count| add(step, name, count, 0) } }
        self
      end

      private

      # Adds count calls for step, a protocol step's String, under provider,
      # and total of them to the step's own count.
      def add(step, provider, count, total = count)
        @llm_calls[step] = @llm_calls.fetch(step, 0) + total
        return unless provider

        calls = @by_provider[provider] ||= {}
        calls[step] = calls.fetch(step, 0) + count
      end
    end
  end
end
