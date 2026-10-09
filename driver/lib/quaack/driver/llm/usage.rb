# frozen_string_literal: true

module Quaack
  module Driver
    module LLM
      # A reply's tokens as an adapter reports them to Client: a Hash of
      # Burndown::TOKENS kinds, holding cached and reasoning only where the
      # provider gives them, or nil when it gives no usage at all.
      module Usage
        module_function

        # An Anthropic or Bedrock message's usage: input counts every input
        # token, cache reads and writes included, and cached the reads.
        def anthropic(usage)
          return unless usage

          read = usage.cache_read_input_tokens
          input = [usage.input_tokens, read, usage.cache_creation_input_tokens].compact.sum
          { "input" => input, "output" => usage.output_tokens, **kept("cached" => read) }
        end

        # An OpenAI-compatible completion's usage.
        def openai(usage)
          return unless usage

          { "input" => usage.prompt_tokens, "output" => usage.completion_tokens,
            **kept("cached" => usage.prompt_tokens_details&.cached_tokens,
                   "reasoning" => usage.completion_tokens_details&.reasoning_tokens) }
        end

        def kept(counts) = counts.compact
      end
    end
  end
end
