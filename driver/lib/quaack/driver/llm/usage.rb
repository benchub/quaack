# frozen_string_literal: true

module Quaack
  module Driver
    module LLM
      # A reply's tokens as an adapter reports them to Client: a Hash of
      # Burndown::TOKENS kinds, holding cached and reasoning only where the
      # provider gives them, or nil when it gives no usage at all, or no
      # count of input or output tokens, as a sloppy server may not. A
      # cached or reasoning count that isn't one is left out.
      module Usage
        module_function

        # An Anthropic or Bedrock message's usage: input counts every input
        # token, cache reads and writes included, and cached the reads.
        def anthropic(usage)
          return unless usage

          read = usage.cache_read_input_tokens
          input = [usage.input_tokens, read, usage.cache_creation_input_tokens].compact.sum
          whole({ "input" => input, "output" => usage.output_tokens, **kept("cached" => read) })
        end

        # An OpenAI-compatible completion's usage, as a Hash with symbol
        # keys, since the gem's own readers raise for a null count.
        def openai(usage)
          raw = plain(usage)
          return unless raw.is_a?(Hash)

          whole({ "input" => raw[:prompt_tokens], "output" => raw[:completion_tokens],
                  **kept("cached" => raw.dig(:prompt_tokens_details, :cached_tokens),
                         "reasoning" => raw.dig(:completion_tokens_details, :reasoning_tokens)) })
        end

        # value, with every model in it turned into a Hash, read without
        # the gem's readers.
        def plain(value)
          return value if value.nil? || value.is_a?(Array) || !value.respond_to?(:to_h)

          value.to_h.transform_values { plain(it) }
        end

        def kept(counts) = counts.select { |_, n| count?(n) }

        # tokens, if its input and output are both counts, else nil.
        def whole(tokens) = (tokens if count?(tokens["input"]) && count?(tokens["output"]))

        def count?(value) = value.is_a?(Integer) && !value.negative?
      end
    end
  end
end
