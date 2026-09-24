# frozen_string_literal: true

module Quaack
  module Driver
    module LLM
      # An LLM call that failed. The rule says how, so a caller can decide
      # what to do without knowing the provider:
      #
      # - llm_rate_limited: still rate limited after the retries ran out.
      # - llm_auth: no API key, or the API refused the key.
      # - llm_bad_request: the API rejected the request itself, such as an
      #   unknown model. Retrying the same request won't help.
      # - llm_unavailable: the API was overloaded, erred, timed out (408),
      #   was locked (409), or couldn't be reached, and the retries ran out.
      # - llm_bad_response: a reply came back but can't be used: it stopped
      #   for any reason but end_turn or stop_sequence, such as max_tokens or
      #   refusal, it had no text, the gem couldn't read it as a message, or
      #   it wasn't the JSON that was asked for.
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
          super("#{rule}: #{detail}")
        end
      end

      # Raised when a Client that would call the real API is built while
      # specs run. See Client.
      class RealClientInSpecs < StandardError; end
    end
  end
end
