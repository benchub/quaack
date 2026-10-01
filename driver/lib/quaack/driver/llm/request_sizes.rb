# frozen_string_literal: true

require "json"

module Quaack
  module Driver
    module LLM
      # How big a request was, for an Error's message: the step, max_tokens,
      # the system prompt's length in characters, and each message's role and
      # length. For a message holding a ```json block, it also gives each
      # top-level key's length, largest first. It never holds content, only
      # sizes, roles, the step, and key names.
      #
      #   [step 5a-5, max_tokens 4000, system 1234 chars,
      #    messages: user 98765 (payload: schema_subset 80000, query 120)]
      #
      # A block that won't parse as a JSON object gets no breakdown.
      class RequestSizes
        JSON_BLOCK = /```json\s*\n(.*?)\n\s*```/m

        def initialize(step:, system:, messages:, max_tokens:)
          @step = step
          @system = system
          @messages = messages
          @max_tokens = max_tokens
        end

        def to_s
          "[step #{@step}, max_tokens #{@max_tokens}, system #{@system.to_s.length} chars, " \
            "messages: #{@messages.map { message(it) }.join(", ")}]"
        end

        private

        def message(msg)
          content = msg[:content].to_s
          keys = keys(content)
          "#{msg[:role]} #{content.length}#{" (payload: #{keys})" if keys}"
        end

        def keys(content)
          block = content[JSON_BLOCK, 1] or return
          payload = JSON.parse(block)
          return unless payload.is_a?(Hash)

          breakdown(payload) unless payload.empty?
        rescue JSON::ParserError
          nil
        end

        def breakdown(payload)
          payload.map { |k, v| [k, JSON.generate(v).length] }.sort_by { |_, n| -n }.map { |k, n| "#{k} #{n}" }
                 .join(", ")
        end
      end
    end
  end
end
