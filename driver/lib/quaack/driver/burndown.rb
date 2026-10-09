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
    #
    # Each provider's wait for replies and tokens, as llm_usage gives them,
    # are counted too, for the report's table of them:
    #
    #   burndown.llm_wait("groq", 1.5, { "input" => 10, "output" => 4 }, used: true)  # a reply it used
    #   burndown.llm_wait("groq", 0.2, nil, used: false)       # no reply came, or no usage was reported
    #   burndown.llm_usage   # => { "groq" => { "seconds" => 1.7, "used" => 1, "reported" => 1,
    #                        #                  "input" => 10, "output" => 4 } }
    class Burndown
      # The token kinds an adapter reports (LLM::Client), each kept only
      # once some reply reports it.
      TOKENS = %w[input output cached reasoning].freeze

      # One Burndown that holds every count of burndowns, added up.
      def self.sum(burndowns) = new.tap { |sum| burndowns.each { sum.add_all(it) } }

      # A Burndown holding steps, counts by step, and providers, each
      # provider's counts by step, as llm_calls and llm_calls_by_provider
      # give them (Provenance's record of earlier processes).
      def self.restore(steps, providers, usage = {})
        new.tap do |burndown|
          burndown.add_usage(usage)
          steps.each { |step, count| burndown.send(:add, step, nil, count) }
          providers.each { |name, calls| calls.each { |step, count| burndown.send(:add, step, name, count, 0) } }
        end
      end

      def initialize
        @llm_calls = {}
        @by_provider = {}
        @usage = {}
      end

      # Counts seconds spent waiting on provider for one ask of its
      # adapter, retries included: tokens are the reply's by TOKENS kind,
      # or nil if no reply came or the provider reported none, and used is
      # whether the client could use the reply.
      def llm_wait(provider, seconds, tokens, used:)
        add_usage(provider => { "seconds" => seconds, "used" => used ? 1 : 0, "reported" => tokens ? 1 : 0,
                                **tokens.to_h.slice(*TOKENS) })
        nil
      end

      # Each provider's wait and tokens so far, as llm_wait adds them up.
      def llm_usage = @usage.transform_values { it.dup.freeze }.freeze

      # Adds usage, as llm_usage gives it, to this one's.
      def add_usage(usage)
        usage.each do |provider, counts|
          sums = @usage[provider] ||= { "seconds" => 0, "used" => 0, "reported" => 0 }
          counts.each { |kind, n| sums[kind] = sums.fetch(kind, 0) + n }
        end
        self
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
        add_usage(other.llm_usage)
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
