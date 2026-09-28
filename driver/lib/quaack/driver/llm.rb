# frozen_string_literal: true

module Quaack
  module Driver
    # The driver's LLM calls. DESIGN.md, "Where QUAACK runs": the driver makes
    # every LLM call, on the engineer's laptop, never in the enclave. Client
    # is the one class that knows it's talking to Anthropic. Callers ask it
    # for text or JSON and see nothing of the SDK, so another provider, or
    # several models at once, can sit behind the same `ask` later.
    #
    # The driver never holds a production value, so a prompt only ever
    # carries shapes. Client doesn't check that. The callers that build the
    # prompts own it.
    module LLM
      DEFAULT_MODEL = "claude-opus-5-5"

      # Overrides the model for every call, over the driver config's.
      MODEL_ENV = "QUAACK_MODEL"

      # The model to use: QUAACK_MODEL if it's set, else the driver config's
      # "model", else DEFAULT_MODEL. An empty value counts as unset. There's no
      # driver config file yet, so a caller passes whatever config it has.
      def self.model(config = {}, env: ENV)
        [env[MODEL_ENV], config["model"]].find { it && !it.empty? } || DEFAULT_MODEL
      end
    end
  end
end

require_relative "llm/error"
require_relative "llm/client"
