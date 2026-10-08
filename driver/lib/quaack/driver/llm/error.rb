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
      #
      # reason is the detail as the adapter gave it, the API's own reason
      # already scrubbed of keys, before Client adds the request's sizes or
      # the router a provider's name, so the router can say why each
      # provider failed.
      class Error < StandardError
        attr_reader :rule, :reason

        def initialize(rule, detail, reason: detail)
          @rule = rule
          @reason = reason
          super("#{rule}: #{detail}")
        end

        # This error, with name, a provider's, after its rule: "llm_bad_request:
        # groq: <detail>". It keeps the reason.
        def naming(name) = Error.new(rule, "#{name}: #{message.delete_prefix("#{rule}: ")}", reason:)
      end

      # Raised when a Client that would call the real API is built while
      # specs run. See Client.
      class RealClientInSpecs < StandardError; end
    end
  end
end
