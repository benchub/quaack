# frozen_string_literal: true

require "anthropic"

# The one chokepoint for the network in specs. Every request the anthropic
# gem sends, retries included, goes out through its HTTP requester's
# execute, unless a middleware answers first the way a Client transport
# does. So this refuses every execute unless QUAACK_ALLOW_REAL_LLM is 1.
# That catches a spec using Anthropic::Client directly, which the guard in
# Quaack::Driver::LLM::Client can't see. The root and driver suites share
# it, and each suite's spec/network_guard_spec.rb tests it.
module NoNetwork
  class Refused < StandardError; end

  module Requester
    def execute(...)
      unless ENV["QUAACK_ALLOW_REAL_LLM"] == "1"
        raise Refused, "a spec tried to send a request to the Anthropic API. " \
                       "Use a transport, such as FakeLLM, or set QUAACK_ALLOW_REAL_LLM=1 to mean it."
      end

      super
    end
  end

  Anthropic::Internal::Transport::PooledNetRequester.prepend(Requester)
end
