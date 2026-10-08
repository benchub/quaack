# frozen_string_literal: true

require "anthropic"
require "json"
require_relative "api_error_detail"
require_relative "error"

module Quaack
  module Driver
    module LLM
      # The Anthropic Messages API, through the official anthropic gem, behind
      # Client. It's the only code that knows about Anthropic: the request's
      # shape, structured output, stop reasons, the gem's retries and
      # credentials, and which of its errors is which rule.
      #
      # Credentials: a key given (specs pass one) wins; then the variable the
      # settings' api_key_env names, which must be set and not empty; else the
      # gem finds them itself, in its own order: ANTHROPIC_API_KEY, then
      # ANTHROPIC_AUTH_TOKEN as a bearer token, then a profile, such as the
      # one `ant auth login` writes. Finding none is llm_auth. The gem takes
      # the first of those variables that's set, even set but empty, and looks
      # no further, so that's llm_auth too, before any attempt.
      #
      # Retries are the gem's own: it retries a 408, 409, 429, or 5xx
      # (including 529, overloaded) and a dropped connection, up to
      # `max_retries` times (the gem's default, two), backing off from half a
      # second up to eight, or as long as the API's retry-after says. With a
      # profile's token, it retries a 401 the same way, rereading the token.
      # Every attempt is an API call, so each one is counted, whether it
      # succeeds or not.
      #
      # `transport` gets each attempt as the gem's Anthropic::APIRequest, plus
      # the step, and returns an Anthropic::APIResponse, standing in for the
      # HTTP call. nil means HTTP.
      class AnthropicAdapter
        NO_CREDENTIALS = "no Anthropic credentials: set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN, " \
                         "or run `ant auth login`"
        # The gem's own messages about a profile can quote its files, so
        # they're left out.
        UNLOADABLE = "the Anthropic credentials couldn't be loaded"
        # The variables the gem reads, in its order, when it's given no key.
        DEFAULT_VARIABLES = %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN].freeze

        # The stop reasons of a reply that finished. Any other, such as
        # max_tokens, refusal, model_context_window_exceeded, pause_turn,
        # tool_use, or one the gem doesn't know, means it isn't whole.
        WHOLE = %i[end_turn stop_sequence].freeze

        # 408 is a timeout and 409 a lock. The gem retries both, so what's
        # left is an API that isn't answering.
        TRANSIENT_STATUSES = [408, 409].freeze

        # A profile's token that can't be read, or exchanged.
        CREDENTIAL_ERRORS = [::Anthropic::Errors::ConfigurationError,
                             ::Anthropic::Credentials::WorkloadIdentityError].freeze

        def initialize(settings:, transport: nil, api_key: nil, max_retries: ::Anthropic::Client::DEFAULT_MAX_RETRIES)
          @model = settings.model
          @transport = transport
          api_key ||= named_key(settings.api_key_env) if settings.api_key_env
          refuse_empty_default unless api_key
          @anthropic = anthropic(api_key, settings.base_url, max_retries)
          raise Error.new("llm_auth", NO_CREDENTIALS) unless credentials?

          @base_url = settings.base_url
          @sent_tokens = []
        end

        # Structured output holds every reply to the schema, so the front
        # never asks again.
        def enforces_schema? = true

        def reply(step:, system:, messages:, max_tokens:, schema:, count:) # rubocop:disable Metrics/ParameterLists
          timeout = nonstreaming_timeout(max_tokens)
          reply_text(send_message(params(system, messages, max_tokens, schema), step, count, timeout))
        rescue ::Anthropic::Errors::APIError => e
          # The gem's error holds the response's headers and whole body.
          # Anthropic's own bodies hold only an error type and message, but
          # base_url can name a gateway or proxy, whose headers or body can
          # echo a key or cookie, and a refused key's body can quote it, so
          # no rule keeps the gem's error as the cause.
          raise Error.new(rule_for(e), detail(e)), cause: nil
        rescue *CREDENTIAL_ERRORS
          raise Error.new("llm_auth", UNLOADABLE), cause: nil
        rescue ::Anthropic::Errors::Error, TypeError, JSON::ParserError
          # A reply the gem can't read raises from its parsing, as a
          # ConversionError, a TypeError, or a JSON::ParserError, some of
          # them quoting the body, so those aren't kept as the cause.
          raise Error.new("llm_bad_response", "the reply couldn't be read as a message"), cause: nil
        end

        private

        # The request, with structured output that matches schema, if
        # there's one.
        def params(system, messages, max_tokens, schema)
          params = { model: @model, max_tokens: max_tokens, messages: messages }
          params[:system_] = system if system
          params[:output_config] = { format_: { type: :json_schema, schema: schema } } if schema
          params
        end

        def named_key(variable)
          key = ENV.fetch(variable) { raise Error.new("llm_auth", "#{variable} isn't set") }
          raise Error.new("llm_auth", "#{variable} is set but empty") if key.empty?

          key
        end

        # The first of DEFAULT_VARIABLES that's set is the one the gem uses,
        # so it mustn't be empty.
        def refuse_empty_default
          variable = DEFAULT_VARIABLES.find { ENV.key?(it) }
          raise Error.new("llm_auth", "#{variable} is set but empty") if variable && ENV[variable].empty?
        end

        # The gem warns that ANTHROPIC_API_KEY takes precedence over a
        # profile whenever a key is used while that variable is set, even a
        # key it was given. A key given here is QUAACK's choice, and the
        # warning would name the wrong variable, so this client skips just
        # that warning. Its others still print.
        class GivenKeyClient < ::Anthropic::Client
          private

          def warn_env_shadow(*, **) = nil
        end

        # The gem reads ANTHROPIC_API_KEY and the rest only when it's given
        # no key.
        def anthropic(api_key, base_url, max_retries)
          (api_key ? GivenKeyClient : ::Anthropic::Client).new(api_key:, base_url:, max_retries:)
        rescue *CREDENTIAL_ERRORS
          raise Error.new("llm_auth", UNLOADABLE), cause: nil
        end

        # An empty key given here counts as none. The gem keeps it as the
        # credential, so it never looks at ANTHROPIC_AUTH_TOKEN or a profile,
        # and then drops the empty header, so it would send no credential.
        def credentials?
          [@anthropic.api_key, @anthropic.auth_token].any? { !it.to_s.empty? } || !@anthropic.credentials.nil?
        end

        # Passing request_options skips the gem's own check of max_tokens
        # against how long a non-streaming request may run, so this runs that
        # check first. Past it, a request needs streaming, which this client
        # doesn't do yet. The timeout it returns goes in request_options.
        def nonstreaming_timeout(max_tokens)
          limit = ::Anthropic::Client::MODEL_NONSTREAMING_TOKENS[@model.to_sym]
          @anthropic.calculate_nonstreaming_timeout(max_tokens, limit)
        rescue ArgumentError
          raise ArgumentError, "max_tokens #{max_tokens} needs streaming, which this client doesn't do", cause: nil
        end

        # Each attempt passes through `count`, inside the gem's retry loop,
        # and then through the transport, if there is one, in place of HTTP.
        # The bearer token each attempt sends is kept for the scrub: a
        # profile's is read only when the request is made, and a 401 makes
        # the gem read it again.
        def send_message(params, step, count, timeout)
          counting = lambda do |request, nxt|
            count.call
            bearer = request.headers["authorization"].to_s.delete_prefix("Bearer ")
            @sent_tokens |= [bearer]
            nxt.call(request)
          end
          middleware = [counting]
          middleware << ->(request, _nxt) { @transport.call(request, step: step) } if @transport
          @anthropic.messages.create(**params, request_options: { middleware: middleware, timeout: timeout })
        end

        def rule_for(error)
          case error
          when ::Anthropic::Errors::RateLimitError then "llm_rate_limited"
          when ::Anthropic::Errors::AuthenticationError, ::Anthropic::Errors::PermissionDeniedError then "llm_auth"
          when ::Anthropic::Errors::InternalServerError, ::Anthropic::Errors::APIConnectionError then "llm_unavailable"
          else TRANSIENT_STATUSES.include?(error.status) ? "llm_unavailable" : "llm_bad_request"
          end
        end

        # An API can quote part of a refused key back, so an llm_auth
        # message is only the status. Any other answer from the API gives
        # its status and the body's own error message, never the whole body
        # or the URL, which the gem's message holds: base_url can name a
        # gateway or proxy whose body echoes a key or anything else. With no
        # answer, such as a dropped connection, it's the gem's message, a
        # fixed sentence. Either way, the adapter's own keys, every bearer
        # token an attempt sent, and what base_url holds are scrubbed out.
        def detail(error)
          return refused(error.status) if rule_for(error) == "llm_auth"

          text = error.status ? APIErrorDetail.answered(error.status, error.body) : error.message
          APIErrorDetail.scrub(text, APIErrorDetail.secrets(@base_url, own_keys))
        end

        # The keys the detail scrubs. The Bedrock adapter has its own.
        def own_keys = [@anthropic.api_key, @anthropic.auth_token, *@sent_tokens]

        def refused(status) = "the API refused the key (#{status})"

        def reply_text(message)
          reason = message.stop_reason
          raise Error.new("llm_bad_response", "the reply stopped for #{reason}") unless WHOLE.include?(reason)

          texts = message.content.select { it.type == :text }.map(&:text)
          raise Error.new("llm_bad_response", "the reply had no text") if texts.empty?

          texts.join
        end
      end
    end
  end
end
