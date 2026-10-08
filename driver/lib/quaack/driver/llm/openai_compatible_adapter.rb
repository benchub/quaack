# frozen_string_literal: true

require "json"
require "openai"
require "uri"
require_relative "api_error_detail"
require_relative "error"

module Quaack
  module Driver
    module LLM
      # An OpenAI-compatible Chat Completions API, through the official openai
      # gem, behind Client. One adapter serves every provider that speaks it:
      # OpenAI, Groq, Google Gemini's OpenAI-compatible endpoint, OpenRouter,
      # and local servers such as Ollama. The settings' base_url picks which;
      # without one, it's OpenAI. Only the settings decide: the gem's own
      # OPENAI_BASE_URL is ignored. The gem's OPENAI_ORG_ID,
      # OPENAI_PROJECT_ID, and OPENAI_CUSTOM_HEADERS go only to OpenAI's own
      # API, never to another provider.
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
      # request that carried response_format (a 400 or 422 whose param is
      # response_format, or whose body names it), the adapter asks once more
      # without it, and if that works it stops sending it for the rest of
      # the run. Both attempts count. Any other 400 or 422, such as a context
      # that's too long, is llm_bad_request at once.
      #
      # Retries are the gem's own: it retries a 408, 409, 429, or 5xx, and a
      # connection that failed before the request went out, up to
      # `max_retries` times (the settings', else the gem's default, two),
      # backing off from half a second up to eight, or as long as the API's
      # retry-after says. A max_retries given to `new` beats both. Every
      # attempt is an API call, so each one is counted, whether it succeeds
      # or not.
      #
      # `transport` gets each attempt as the gem's OpenAI::HTTPClient::Request,
      # plus the step, and returns an OpenAI::HTTPClient::Response, standing
      # in for the HTTP call. nil means HTTP, through the gem's
      # NetHTTPClient.
      class OpenAICompatibleAdapter
        DEFAULT_KEY_ENV = "OPENAI_API_KEY"

        # The name the token limit goes under, unless the settings'
        # token_limit_param names another: Ollama reads only max_tokens.
        DEFAULT_TOKEN_LIMIT_PARAM = "max_completion_tokens"

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

        # Where asks go without a base_url, and its host, the only one that
        # hears the gem's OpenAI settings.
        OPENAI_BASE_URL = "https://api.openai.com/v1"
        OPENAI_HOST = "api.openai.com"

        # The request parameter a rejection of the schema names.
        SCHEMA_PARAM = "response_format"

        def initialize(settings:, transport: nil, api_key: nil, max_retries: nil)
          max_retries ||= settings.max_retries || ::OpenAI::Client::DEFAULT_MAX_RETRIES
          @model = settings.model
          @token_limit_param = (settings.token_limit_param || DEFAULT_TOKEN_LIMIT_PARAM).to_sym
          @schema_mode = true
          @attempts = Attempts.new(transport)
          api_key ||= named_key(settings.api_key_env || DEFAULT_KEY_ENV)
          @base_url = base_url = settings.base_url || OPENAI_BASE_URL
          @openai = ::OpenAI::Client.new(api_key:, max_retries:, http_client: @attempts, base_url:,
                                         **openai_only(base_url))
          @custom_headers = custom_header_values
        end

        def enforces_schema? = false

        def reply(step:, system:, messages:, max_tokens:, schema:, count:) # rubocop:disable Metrics/ParameterLists
          system = [system, SCHEMA_LINE + JSON.generate(schema)].compact.join("\n\n") if schema
          params = { model: @model, @token_limit_param => max_tokens, messages: chat(system, messages) }
          @attempts.during(count, step) { reply_text(complete(params, schema)) }
        rescue ::OpenAI::Errors::APIError => e
          # The gem's error holds the response's headers and whole body,
          # which a refused key's can quote, and which a gateway or proxy's
          # can echo a key or cookie in on any status, so no rule keeps it
          # as the cause. The detail takes only the body's error message.
          raise Error.new(rule_for(e), detail(e)), cause: nil
        rescue ::OpenAI::Errors::Error, JSON::ParserError, Unreadable
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
            walkable(@transport ? @transport.call(request, step: @step) : @http.execute(request))
          end

          private

          # The gem decodes a 2xx body as JSON only when its content-type
          # matches the gem's JSON_CONTENT, and then walks its choices, each
          # choice's message, and each message's tool calls and their
          # functions before it checks their types. A body that's anything
          # else would make it raise a NoMethodError or KeyError, which
          # can't be told from a bug in the driver, so it's Unreadable
          # here, as the reply comes in. The body is read whole, so the
          # response handed on is a copy holding it.
          def walkable(response)
            return response unless response.status < 300

            body = response.body.to_a.join
            unless ::OpenAI::Internal::Util::JSON_CONTENT.match?(response.headers["content-type"].to_s) &&
                   completion?(body)
              raise Unreadable, "the reply isn't a completion the gem can walk"
            end

            ::OpenAI::HTTPClient::Response.new(status: response.status, headers: response.headers, body: body)
          end

          # A JSON object whose choices, if there are any, are objects the
          # gem can walk, holding no number past a float's range. Choices
          # that are null or missing it reports itself, or reply_text does.
          # A body that isn't JSON raises a JSON::ParserError, which reply
          # rescues.
          def completion?(body)
            parsed = JSON.parse(body)
            parsed.is_a?(Hash) && objects?(parsed["choices"]) { choice?(it) } && finite?(parsed)
          end

          # JSON reads a number past a float's range as Infinity, which the
          # gem's coercion to an integer raises a FloatDomainError on.
          def finite?(value)
            case value
            when Hash then value.each_value.all? { finite?(it) }
            when Array then value.all? { finite?(it) }
            when Float then value.finite?
            else true
            end
          end

          # Every choice has a message, so reply_text can read the first.
          def choice?(choice)
            message = choice["message"]
            message.is_a?(Hash) && objects?(message["tool_calls"]) { tool_call?(it) }
          end

          # The gem passes over a custom tool call, whatever its custom
          # holds, and reads any other's function name.
          def tool_call?(call)
            return true if call["type"] == "custom"

            call["function"].is_a?(Hash) && call["function"].key?("name")
          end

          # Whether value is null, or an array of JSON objects that each pass
          # the block.
          def objects?(value, &) = value.nil? || (value.is_a?(Array) && value.all? { it.is_a?(Hash) && yield(it) })
        end

        # A 2xx reply the gem can't walk.
        class Unreadable < StandardError; end

        private

        def named_key(variable)
          key = ENV.fetch(variable, nil)
          raise Error.new("llm_auth", "#{variable} isn't set") if key.nil?
          raise Error.new("llm_auth", "#{variable} is set but empty") if key.empty?

          key
        end

        # The gem's OpenAI settings, for any host but OpenAI's, turned off:
        # no organization or project, and, through the gem's marker for
        # headers already resolved, no OPENAI_CUSTOM_HEADERS. For OpenAI's,
        # nothing, so the gem reads them as usual.
        def openai_only(base_url)
          return {} if URI(base_url).host.downcase == OPENAI_HOST

          { organization: nil, project: nil, default_headers: ::OpenAI::Internal::ClientOptions::ResolvedHeaders.new }
        end

        # The system prompt, if there is one, is the first message.
        def chat(system, messages)
          system ? [{ role: "system", content: system }, *messages] : messages
        end

        # The completion, asking for output that matches schema while the
        # API takes response_format.
        def complete(params, schema)
          return create(**params) unless schema && @schema_mode

          begin
            create(**params, response_format: response_format(schema))
          rescue *REJECTED => e
            raise unless schema_rejected?(e)

            completion = create(**params)
            @schema_mode = false
            completion
          end
        end

        # One completion. Attempts has checked a 2xx reply's shape first.
        def create(**) = @openai.chat.completions.create(**)

        # Whether a request was rejected for its response_format: the error
        # names it as its param, or, for an API that names none, its body
        # mentions it.
        def schema_rejected?(error)
          error.param == SCHEMA_PARAM || error.body.to_s.include?(SCHEMA_PARAM)
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
        # is only the status. Any other answer from the API gives its status
        # and the body's error message, if it has one (APIErrorDetail, or a
        # string error, as Hugging Face TGI sends), never
        # the rest of the body or the gem's message, which holds the URL. As
        # in the Anthropic adapter, a body with no message, or one that's
        # text, gives only the status. With no answer, such as a dropped
        # connection, it's the gem's message, a fixed sentence. Either way,
        # the key, OpenAI's organization, project, and custom header values,
        # and what base_url holds are scrubbed out (APIErrorDetail), since a
        # gateway or proxy at base_url can echo any of them.
        def detail(error)
          return "the API refused the key (#{error.status})" if rule_for(error) == "llm_auth"

          APIErrorDetail.cut(APIErrorDetail.scrub(answered(error), APIErrorDetail.secrets(@base_url, own_keys)))
        end

        def answered(error)
          return error.message unless error.status

          APIErrorDetail.answered(error.status, error.body, reason: body_message(error.body))
        end

        # The body's message as APIErrorDetail reads it, or, as servers such
        # as Hugging Face TGI send it, a non-empty string error. A body that's
        # a JSON array, as Gemini seems to send, gives its first element's
        # message, or with none there, the whole body as JSON (task
        # 20261001-5). detail scrubs it and cuts it to APIErrorDetail::DETAIL_MAX.
        def body_message(body)
          return APIErrorDetail.array_message(body) { body_message(it) } if body.is_a?(Array)

          inner = body[:error] if body.is_a?(Hash)
          inner.is_a?(String) && !inner.empty? ? inner : APIErrorDetail.body_message(body)
        end

        # The keys the detail scrubs: the key, and the organization, project,
        # and OPENAI_CUSTOM_HEADERS values the gem sends to OpenAI's own API.
        def own_keys = [@openai.api_key, @openai.organization, @openai.project, *@custom_headers].compact

        # The values of OPENAI_CUSTOM_HEADERS, read as the gem reads them:
        # one "Name: value" a line. Only OpenAI's own API hears them, but
        # they're scrubbed for any host, which costs nothing.
        def custom_header_values
          ENV.fetch("OPENAI_CUSTOM_HEADERS", "").split("\n").filter_map { it.split(":", 2)[1]&.strip }
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
