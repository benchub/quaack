# frozen_string_literal: true

require "anthropic"
require_relative "error"
require_relative "anthropic_adapter"

module Quaack
  module Driver
    module LLM
      # Anthropic models on AWS Bedrock, through the anthropic gem's
      # BedrockClient, behind Client. It's the Anthropic adapter with
      # Bedrock's credentials, region, and edge: the request, structured
      # output, stop reasons, retries, and which error is which rule are all
      # the Anthropic adapter's, since Bedrock takes the same Messages API.
      # The gem rewrites each request to Bedrock's invoke URL, with the model
      # in the URL, and signs it.
      #
      # Credentials. QUAACK stores none. A Bedrock API key in
      # AWS_BEARER_TOKEN_BEDROCK, when that's set, is sent as a bearer token;
      # set but empty is llm_auth, and it can't be used with llm.aws_profile.
      # Otherwise the AWS SDK's own credential chain finds them: the profile
      # llm.aws_profile names, or else AWS_ACCESS_KEY_ID and
      # AWS_SECRET_ACCESS_KEY, AWS_PROFILE or the default profile in
      # ~/.aws (static keys, SSO, assume-role, or credential_process), and
      # the container or EC2 instance role. Each request is signed with SigV4
      # with what it found. Keys given (specs pass fake ones) take the chain's
      # place. Finding none, or a chain that fails, is llm_auth, before any
      # attempt. The gem takes the chain's credentials once, when the client
      # is built, as it always does, so ones that expire during a run, such
      # as an SSO session's, are refused then: llm_auth.
      #
      # The region is llm.aws_region, else the SDK's lookup: AWS_REGION,
      # AWS_DEFAULT_REGION, then the profile's. With a Bedrock API key the
      # gem looks up nothing, so it's llm.aws_region, AWS_REGION, or
      # AWS_DEFAULT_REGION. No region is a usage error, before any attempt,
      # unless there's a base URL, which a key needs no region for. So is a
      # bad AWS_REGION or AWS_DEFAULT_REGION, when there's no llm.aws_region,
      # checked as llm.aws_region is, and named, not quoted.
      #
      # `transport` gets each attempt as it would go out, rewritten and
      # signed, as the gem's Anthropic::APIRequest, plus the step, and
      # returns an Anthropic::APIResponse, standing in for the HTTP call.
      # nil means HTTP.
      class BedrockAdapter < AnthropicAdapter
        BEARER_ENV = "AWS_BEARER_TOKEN_BEDROCK"
        REGION_VARIABLES = %w[AWS_REGION AWS_DEFAULT_REGION].freeze

        NO_CREDENTIALS = "no AWS credentials: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, name a profile in " \
                         "llm.aws_profile in #{FILE} or AWS_PROFILE, or set #{BEARER_ENV}".freeze
        # The chain's own messages can quote its files and commands, so
        # they're left out.
        UNLOADABLE = "the AWS credentials couldn't be loaded"
        NO_REGION = "no AWS region for Bedrock: set llm.aws_region in #{FILE}, AWS_REGION, or a region in the " \
                    "AWS profile".freeze
        BOTH = "llm.aws_profile in #{FILE} can't be used while #{BEARER_ENV} is set: unset one".freeze

        # The Anthropic adapter's initialize finds Anthropic's credentials,
        # so it isn't called: this sets up the same state from AWS's.
        def initialize(settings:, transport: nil, aws_access_key: nil, aws_secret_key: nil, # rubocop:disable Lint/MissingSuper
                       max_retries: ::Anthropic::Client::DEFAULT_MAX_RETRIES)
          @model = settings.model
          given = [aws_access_key, aws_secret_key] if aws_access_key
          options = ENV.key?(BEARER_ENV) ? bearer(settings) : signing(settings, given)
          edge = transport && ->(request) { transport.call(request, step: @step) }
          @anthropic = EdgeClient.new(edge:, base_url: settings.base_url, max_retries:, **options)
        end

        # The gem's BedrockClient, with an edge standing in for HTTP past
        # its Bedrock step, which rewrites and signs each attempt. nil edge
        # means HTTP.
        class EdgeClient < ::Anthropic::BedrockClient
          def initialize(edge:, **)
            @edge = edge
            super(**)
          end

          private

          def provider_middleware
            bedrock = super
            @edge ? ->(request, _nxt) { bedrock.call(request, @edge) } : bedrock
          end
        end

        private

        # An llm_auth for a refused request carries only the status, as the
        # Anthropic adapter's does: AWS's message about a signature can
        # describe the request that was signed.
        def refused(status) = "AWS refused the credentials (#{status})"

        # The client's options for a Bedrock API key, which the gem reads
        # from BEARER_ENV itself.
        def bearer(settings)
          raise Error.new("llm_auth", "#{BEARER_ENV} is set but empty") if ENV[BEARER_ENV].empty?
          raise ConfigError, BOTH if settings.aws_profile

          region = settings.aws_region || env_region
          raise ConfigError, NO_REGION unless region || settings.base_url

          { aws_region: region }
        end

        # The client's options for signing: the region and credentials the
        # AWS SDK finds, or the keys given.
        def signing(settings, given)
          env_region unless settings.aws_region
          region, credentials = aws(settings, given)
          raise Error.new("llm_auth", NO_CREDENTIALS) unless credentials&.set?

          { aws_region: region, aws_access_key: credentials.access_key_id,
            aws_secret_key: credentials.secret_access_key, aws_session_token: credentials.session_token }
        end

        # The first of REGION_VARIABLES that's set and not empty, or nil.
        # Raises if it isn't a region.
        def env_region
          name = REGION_VARIABLES.find { !ENV[it].to_s.empty? } or return
          region = ENV.fetch(name)
          ok, problem = CHECKS.fetch("aws_region")
          raise ConfigError, "#{name} #{problem}" unless ok.call(region)

          region
        end

        # The region and credentials the AWS SDK finds for the settings, as
        # the gem's BedrockClient would find them, or nil credentials. The
        # chain's providers (SSO, assume-role, web identity,
        # credential_process) each fail with their own errors, so any error
        # the chain raises is llm_auth.
        def aws(settings, given)
          require "aws-sdk-bedrockruntime"
          options = { region: settings.aws_region, profile: settings.aws_profile }.compact
          options[:credentials] = ::Aws::Credentials.new(*given) if given
          config = ::Aws::BedrockRuntime::Client.new(**options).config
          [config.region, config.credentials&.credentials]
        rescue ::Aws::Errors::MissingRegionError
          raise ConfigError, NO_REGION, cause: nil
        rescue StandardError
          raise Error.new("llm_auth", UNLOADABLE), cause: nil
        end

        # Each attempt passes through `count`, inside the gem's retry loop,
        # and then the gem's Bedrock step and the edge.
        def send_message(params, step, count, timeout)
          @step = step
          counting = lambda do |request, nxt|
            count.call
            nxt.call(request)
          end
          @anthropic.messages.create(**params, request_options: { middleware: [counting], timeout: timeout })
        end
      end
    end
  end
end
