# frozen_string_literal: true

require "anthropic"
require "json"
require_relative "error"

module Quaack
  module Driver
    module LLM
      # Asks Claude through the Anthropic Messages API, using the official
      # anthropic gem. It's the only code that knows about Anthropic: `ask`
      # takes a step and a conversation and returns text or parsed JSON.
      #
      #   client = Client.new(burndown: burndown)
      #   client.ask(step: "5a-5", system: "...", messages: [{ role: "user", content: "..." }],
      #              max_tokens: 4000)                          # => "CREATE INDEX ..."
      #   client.ask(step: "6a", ..., schema: { type: "object", ... })   # => { "rewrites" => [...] }
      #
      # Retries are the gem's own: it retries a 408, 409, 429, or 5xx
      # (including 529, overloaded) and a dropped connection, up to
      # `max_retries` times (the gem's default, two), backing off from half a
      # second up to eight, or as long as the API's retry-after says. Every
      # attempt is an API call, so each one counts once in the burndown under
      # its step, whether it succeeds or not.
      #
      # `transport` is the edge specs fake. It gets each attempt as the gem's
      # Anthropic::APIRequest, plus the step, and returns an
      # Anthropic::APIResponse, standing in for the HTTP call. Leave it nil to
      # call the real API. While specs run, that raises RealClientInSpecs,
      # unless QUAACK_ALLOW_REAL_LLM is 1, so no spec reaches the network by
      # mistake. Specs are running if RSpec is loaded or QUAACK_SPECS is 1,
      # which the spec helpers set so child processes inherit it.
      class Client
        API_KEY_ENV = "ANTHROPIC_API_KEY"
        ALLOW_REAL_ENV = "QUAACK_ALLOW_REAL_LLM"
        SPECS_ENV = "QUAACK_SPECS"

        def initialize(burndown:, api_key: ENV.fetch(API_KEY_ENV, nil), model: LLM.model, transport: nil,
                       max_retries: Anthropic::Client::DEFAULT_MAX_RETRIES)
          refuse_real_client_in_specs unless transport
          raise Error.new("llm_auth", "#{API_KEY_ENV} isn't set") if api_key.to_s.empty?

          @burndown = burndown
          @model = model
          @transport = transport
          @anthropic = Anthropic::Client.new(api_key: api_key, max_retries: max_retries)
        end

        # Asks for one reply and returns its text. With `schema`, a JSON
        # schema, it asks for structured output that matches it and returns
        # the parsed JSON. With `json: true` and no schema, it parses the
        # text as JSON, for a prompt that asks for JSON itself.
        def ask(step:, messages:, max_tokens:, system: nil, schema: nil, json: false) # rubocop:disable Metrics/ParameterLists
          params = { model: @model, max_tokens: max_tokens, messages: messages }
          params[:system_] = system if system
          params[:output_config] = { format_: { type: :json_schema, schema: schema } } if schema
          text = reply_text(send_message(params, step))
          schema || json ? parse_json(text) : text
        end

        private

        def refuse_real_client_in_specs
          return unless defined?(::RSpec) || ENV[SPECS_ENV] == "1"
          return if ENV[ALLOW_REAL_ENV] == "1"

          raise RealClientInSpecs, "a spec built an LLM client that would call the real API. " \
                                   "Pass a transport, such as FakeLLM, or set #{ALLOW_REAL_ENV}=1 to mean it."
        end

        # Each attempt passes through `count`, inside the gem's retry loop,
        # and then through the transport, if there is one, in place of HTTP.
        # Burndown#llm_call refuses a step that isn't one of
        # Protocol::Burndown::LLM_STEPS, and `count` runs first, so a bad
        # step raises ArgumentError before any attempt goes out.
        def send_message(params, step)
          count = lambda do |request, nxt|
            @burndown.llm_call(step)
            nxt.call(request)
          end
          middleware = [count]
          middleware << ->(request, _nxt) { @transport.call(request, step: step) } if @transport
          @anthropic.messages.create(**params, request_options: { middleware: middleware })
        rescue Anthropic::Errors::APIError => e
          raise Error.new(rule_for(e), e.message)
        end

        def rule_for(error)
          case error
          when Anthropic::Errors::RateLimitError then "llm_rate_limited"
          when Anthropic::Errors::AuthenticationError, Anthropic::Errors::PermissionDeniedError then "llm_auth"
          when Anthropic::Errors::InternalServerError, Anthropic::Errors::APIConnectionError then "llm_unavailable"
          else "llm_bad_request"
          end
        end

        def reply_text(message)
          case message.stop_reason
          when :max_tokens then raise Error.new("llm_bad_response", "the reply was cut short at max_tokens")
          when :refusal then raise Error.new("llm_bad_response", "the model refused")
          end
          texts = message.content.select { it.type == :text }.map(&:text)
          raise Error.new("llm_bad_response", "the reply had no text") if texts.empty?

          texts.join
        end

        # The message leaves the reply out, and so does the parser's, which
        # quotes it. Replies carry only shapes, but a message has no need
        # for one.
        def parse_json(text)
          JSON.parse(text)
        rescue JSON::ParserError
          raise Error.new("llm_bad_response", "the reply wasn't valid JSON"), cause: nil
        end
      end
    end
  end
end
