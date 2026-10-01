# frozen_string_literal: true

require "json"
require "openai"
require_relative "error"

module Quaack
  module Driver
    module LLM
      # An OpenAI-compatible Chat Completions API, through the official openai
      # gem, behind Client. One adapter serves every provider that speaks it:
      # OpenAI, Groq, Google Gemini's OpenAI-compatible endpoint, OpenRouter,
      # and local servers such as Ollama. The settings' base_url picks which;
      # without one, the gem's own lookup applies: OPENAI_BASE_URL, then
      # OpenAI.
      #
      # Credentials: a key given (specs pass one) wins; then the variable the
      # settings' api_key_env names, or OPENAI_API_KEY when they name none.
      # It's sent as a bearer token. A variable that's unset or empty is
      # llm_auth, before any attempt.
      #
      # Schemas. Not every provider or model holds a reply to a schema, and
      # some take response_format and still don't, so enforces_schema? is
      # false: the front checks every reply and asks once more when one
      # doesn't match. The schema goes in the system prompt, after the
      # JSON-only line, so the model sees it either way. It's also sent as a
      # response_format of type json_schema, without strict, since not every
      # schema QUAACK uses fits strict mode's rules. When the API rejects a
      # request that carried response_format (a 400 or 422), the adapter asks
      # once more without it, and if that works it stops sending it for the
      # rest of the run. Both attempts count.
      #
      # Retries are the gem's own: it retries a 408, 409, 429, or 5xx, and a
      # connection that failed before the request went out, up to
      # `max_retries` times (the gem's default, two), backing off from half a
      # second up to eight, or as long as the API's retry-after says. Every
      # attempt is an API call, so each one is counted, whether it succeeds
      # or not.
      #
      # `transport` gets each attempt as the gem's OpenAI::HTTPClient::Request,
      # plus the step, and returns an OpenAI::HTTPClient::Response, standing
      # in for the HTTP call. nil means HTTP, through the gem's
      # NetHTTPClient.
      class OpenAICompatibleAdapter
        DEFAULT_KEY_ENV = "OPENAI_API_KEY"

        # The one finish reason of a reply that finished. Any other, such as
        # length, content_filter, tool_calls, or one the gem doesn't know,
        # means it isn't whole.
        WHOLE = "stop"

        # 408 is a timeout and 409 a lock. The gem retries both, so what's
        # left is an API that isn't answering.
        TRANSIENT_STATUSES = [408, 409].freeze

        # What an API that doesn't take response_format answers.
        REJECTED = [::OpenAI::Errors::BadRequestError, ::OpenAI::Errors::UnprocessableEntityError].freeze

        SCHEMA_LINE = "The JSON object must match this JSON schema: "

        def initialize(settings:, transport: nil, api_key: nil, max_retries: ::OpenAI::Client::DEFAULT_MAX_RETRIES)
          @model = settings.model
          @schema_mode = true
          @attempts = Attempts.new(transport)
          api_key ||= named_key(settings.api_key_env || DEFAULT_KEY_ENV)
          options = { api_key:, max_retries:, http_client: @attempts }
          options[:base_url] = settings.base_url if settings.base_url
          @openai = ::OpenAI::Client.new(**options)
        end

        def enforces_schema? = false

        def reply(step:, system:, messages:, max_tokens:, schema:, count:) # rubocop:disable Metrics/ParameterLists
          system = [system, SCHEMA_LINE + JSON.generate(schema)].compact.join("\n\n") if schema
          params = { model: @model, max_completion_tokens: max_tokens, messages: chat(system, messages) }
          @attempts.during(count, step) { reply_text(complete(params, schema)) }
        rescue ::OpenAI::Errors::APIError => e
          raise Error.new(rule_for(e), detail(e))
        rescue ::OpenAI::Errors::Error, TypeError, JSON::ParserError
          # A reply the gem can't read raises from its parsing, some of these
          # quoting the body, so they aren't kept as the cause.
          raise Error.new("llm_bad_response", "the reply couldn't be read as a message"), cause: nil
        end

        # The gem's HTTP client, standing in front of the real one or the
        # transport: it counts each attempt, for the ask under way, before
        # the attempt goes out. The driver makes one ask at a time.
        class Attempts
          def initialize(transport)
            @transport = transport
            @http = ::OpenAI::NetHTTPClient.new unless transport
          end

          # Runs the block with each attempt counted by count, under step.
          def during(count, step)
            @count = count
            @step = step
            yield
          ensure
            @count = @step = nil
          end

          def execute(request)
            @count.call
            @transport ? @transport.call(request, step: @step) : @http.execute(request)
          end
        end

        private

        def named_key(variable)
          key = ENV.fetch(variable, nil)
          raise Error.new("llm_auth", "#{variable} isn't set") if key.nil?
          raise Error.new("llm_auth", "#{variable} is set but empty") if key.empty?

          key
        end

        # The system prompt, if there is one, is the first message.
        def chat(system, messages)
          system ? [{ role: "system", content: system }, *messages] : messages
        end

        # The completion, asking for output that matches schema while the
        # API takes response_format.
        def complete(params, schema)
          completions = @openai.chat.completions
          return completions.create(**params) unless schema && @schema_mode

          begin
            completions.create(**params, response_format: response_format(schema))
          rescue *REJECTED
            completion = completions.create(**params)
            @schema_mode = false
            completion
          end
        end

        def response_format(schema) = { type: :json_schema, json_schema: { name: "reply", schema: schema } }

        def rule_for(error)
          case error
          when ::OpenAI::Errors::RateLimitError then "llm_rate_limited"
          when ::OpenAI::Errors::AuthenticationError, ::OpenAI::Errors::PermissionDeniedError then "llm_auth"
          when ::OpenAI::Errors::InternalServerError, ::OpenAI::Errors::APIConnectionError then "llm_unavailable"
          else TRANSIENT_STATUSES.include?(error.status) ? "llm_unavailable" : "llm_bad_request"
          end
        end

        # Some APIs quote part of a refused key back, so an llm_auth message
        # is only the status. Any other message is the gem's, which holds
        # only the status and URL, then the provider's explanation from the
        # body.
        def detail(error)
          return "the API refused the key (#{error.status})" if rule_for(error) == "llm_auth"

          explanation = body_text(error.respond_to?(:body) ? error.body : nil)
          explanation ? "#{error.message}: #{explanation}" : error.message
        end

        # The error object's message from a JSON body, the whole body as
        # JSON without one, or a text body as it is.
        def body_text(body)
          case body
          when Hash then hash_text(body)
          when String then body unless body.empty?
          end
        end

        def hash_text(body)
          inner = body.transform_keys(&:to_s)["error"]
          message = inner.transform_keys(&:to_s)["message"] if inner.is_a?(Hash)
          message.is_a?(String) ? message : JSON.generate(body)
        end

        # A 200 with no choices at all, such as a proxy's error object, has
        # nil for them.
        def reply_text(completion)
          choice = completion.choices&.first or bad_response("the reply had no choices")
          reason = choice.finish_reason
          bad_response("the reply stopped for #{reason}") unless reason.to_s == WHOLE

          message = choice.message
          bad_response("the reply was a refusal") if message.refusal
          bad_response("the reply had no text") if message.content.to_s.empty?
          message.content
        end

        def bad_response(detail) = raise(Error.new("llm_bad_response", detail))
      end
    end
  end
end
