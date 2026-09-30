# frozen_string_literal: true

require "anthropic"
require "openai"

# The one chokepoint for the network in specs. Every request the anthropic
# gem sends, retries included, goes out through its HTTP requester's
# execute, unless a middleware answers first the way a Client transport
# does. The openai gem's requests all go out through its NetHTTPClient's
# execute in the same way, unless the adapter is given a transport. So this
# refuses every execute of either unless QUAACK_ALLOW_REAL_LLM is 1. That
# catches a spec using Anthropic::Client or OpenAI::Client directly, which
# the guard in Quaack::Driver::LLM::Client can't see. The root and driver
# suites share it, and each suite's spec/network_guard_spec.rb tests it.
module NoNetwork
  class Refused < StandardError; end

  # For the block, refuses every request even with QUAACK_ALLOW_REAL_LLM=1,
  # for a spec that sets the opt-in only to build a client without a
  # transport, so the guard still stands if that client tries to send.
  def self.always_refuse
    @always = true
    yield
  ensure
    @always = false
  end

  def self.always? = @always == true

  module Requester
    def execute(...)
      if NoNetwork.always? || ENV["QUAACK_ALLOW_REAL_LLM"] != "1"
        raise Refused, "a spec tried to send a request to an LLM API. " \
                       "Use a transport, such as FakeLLM, or set QUAACK_ALLOW_REAL_LLM=1 to mean it."
      end

      super
    end
  end

  Anthropic::Internal::Transport::PooledNetRequester.prepend(Requester)
  OpenAI::NetHTTPClient.prepend(Requester)
end
