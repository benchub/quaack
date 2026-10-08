# frozen_string_literal: true

module Quaack
  module Driver
    # The driver's LLM calls. DESIGN.md, "Where QUAACK runs": the driver makes
    # every LLM call, on the engineer's laptop, never in the enclave.
    #
    # Client is the front callers use: it asks for text or JSON, and it owns
    # the burndown count, JSON parsing, and the error rules. Behind it sits
    # one adapter per provider, which is the only code that knows that
    # provider's API. Callers see nothing of either SDK.
    #
    # Which provider and model come from the llm block of the driver config,
    # ~/.quaack/driver.json, with environment overrides. See `settings`, and
    # `providers` for the llms list that may replace the block. The
    # providers are anthropic (the Anthropic API), openai_compatible (any
    # OpenAI-compatible Chat Completions API), bedrock (Anthropic models on
    # AWS Bedrock), and copilot_cli (a local `copilot` command).
    #
    # The driver never holds a production value, so a prompt only ever
    # carries shapes. Client doesn't check that. The callers that build the
    # prompts own it.
    module LLM
      DEFAULT_MODEL = "claude-opus-5-5"
      COPILOT_CLI_DEFAULT_MODEL = "claude-opus-5.5"

      # Override the llm block's model, provider, and base_url.
      MODEL_ENV = "QUAACK_MODEL"
      PROVIDER_ENV = "QUAACK_LLM_PROVIDER"
      BASE_URL_ENV = "QUAACK_LLM_BASE_URL"

      # Every provider the llm block may name, and the default model of each
      # that has one. Any other needs a model.
      PROVIDERS = %w[anthropic openai_compatible bedrock copilot_cli].freeze
      DEFAULT_MODELS = { "anthropic" => DEFAULT_MODEL, "copilot_cli" => COPILOT_CLI_DEFAULT_MODEL }.freeze

      # The adapter class for each provider, by constant name under LLM.
      ADAPTERS = { "anthropic" => :AnthropicAdapter, "openai_compatible" => :OpenAICompatibleAdapter,
                   "bedrock" => :BedrockAdapter, "copilot_cli" => :CopilotCLIAdapter }.freeze

      # Each SDK takes about half a second to load, so an adapter that needs
      # one loads, and loads its SDK, only when `adapter` first names it.
      autoload :AnthropicAdapter, File.expand_path("llm/anthropic_adapter", __dir__)
      autoload :OpenAICompatibleAdapter, File.expand_path("llm/openai_compatible_adapter", __dir__)
      autoload :BedrockAdapter, File.expand_path("llm/bedrock_adapter", __dir__)

      BLOCK = "llm"
      FILE = "~/.quaack/driver.json"

      # A bad llm block or override. The message names the key or the
      # variable, never its value, which might be a key pasted in the wrong
      # place.
      class ConfigError < StandardError; end

      # What an adapter is built from. base_url nil means the provider's own
      # default. api_key_env is the name of the variable that holds the key,
      # or nil for the provider's usual lookup. aws_region and aws_profile are
      # bedrock's, each nil for the AWS SDK's own lookup. command_template and
      # timeout_seconds are copilot_cli's, nil for its defaults. at is where
      # the settings sit in the file, llm or an entry such as llms[2], for an
      # adapter's messages that name a key.
      Settings = Data.define(:provider, :model, :base_url, :api_key_env, :aws_region, :aws_profile,
                             :command_template, :timeout_seconds, :at)

      NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      LINE = /\A[^\n\r]*\S[^\n\r]*\z/
      URL = %r{\Ahttps?://[^\s/]+\S*\z}
      # A full chat completions endpoint, which provider docs often show. The
      # openai gem adds /chat/completions to base_url itself, so this one
      # would 404.
      ENDPOINT = %r{/chat/completions/?\z}
      NOT_ROOT = "must be the API root, such as https://api.groq.com/openai/v1, without /chat/completions"
      # An AWS region's name, such as us-east-1, us-gov-west-1, or
      # eusc-de-east-1.
      REGION = /\A[a-z]{2,4}(-[a-z]+)+-\d+\z/

      # Each key of the block: whether a value is good, and what a bad one
      # is told.
      CHECKS = {
        "provider" => [->(v) { PROVIDERS.include?(v) }, "must be #{PROVIDERS[0..-2].join(", ")}, or #{PROVIDERS.last}"],
        "model" => [->(v) { v.is_a?(String) && LINE.match?(v) }, "must be a non-empty string"],
        "base_url" => [->(v) { v.is_a?(String) && URL.match?(v) }, "must be an http or https URL"],
        "api_key_env" => [->(v) { v.is_a?(String) && NAME.match?(v) }, "must be the name of an environment variable"],
        "aws_region" => [->(v) { v.is_a?(String) && REGION.match?(v) }, "must be an AWS region, such as us-east-1"],
        "aws_profile" => [->(v) { v.is_a?(String) && LINE.match?(v) }, "must be the name of an AWS profile"],
        "command_template" => [->(v) { command_template?(v) },
                               "must be an argv array with {prompt_file} and {model} placeholders"],
        "timeout_seconds" => [->(v) { v.is_a?(Numeric) && v.positive? && v.finite? }, "must be a positive number"]
      }.freeze
      KEYS = CHECKS.keys.freeze

      # The keys that apply only to some providers, and which. bedrock's
      # credentials come from AWS, so it has no api_key_env.
      ONLY = { "base_url" => %w[anthropic openai_compatible bedrock],
               "api_key_env" => %w[anthropic openai_compatible], "aws_region" => %w[bedrock],
               "aws_profile" => %w[bedrock], "command_template" => %w[copilot_cli],
               "timeout_seconds" => %w[copilot_cli] }.freeze

      # The variable that overrides each key that has one.
      VARIABLES = { "provider" => PROVIDER_ENV, "model" => MODEL_ENV, "base_url" => BASE_URL_ENV }.freeze

      # The Settings from `block`, the parsed llm block of the driver config
      # (nil when there's none), and env. QUAACK_MODEL, QUAACK_LLM_PROVIDER,
      # and QUAACK_LLM_BASE_URL override the block, and an empty one counts
      # as unset. With neither, it's Anthropic with DEFAULT_MODEL. Raises
      # ConfigError for a bad value, or a key that doesn't apply to the
      # provider. When QUAACK_LLM_PROVIDER switches to another provider than
      # the block's, every key of the block is checked and then ignored, so
      # the switch works for one run: the block's base_url and api_key_env
      # are meant for its own provider, and that provider's credentials must
      # never go to them. The model and base_url then come only from
      # QUAACK_MODEL and QUAACK_LLM_BASE_URL, or the new provider's defaults.
      #
      # at is where the block sits in the file, for messages, such as
      # llms[2] for an entry of the llms list (see `providers`).
      def self.settings(block = nil, env: ENV, at: BLOCK)
        block, provider, switched = for_provider(check_block(block, at), env, at)
        model = pick(env, block, "model") || DEFAULT_MODELS[provider]
        model or raise ConfigError, no_model(provider, switched, at)
        base_url = pick(env, block, "base_url")
        check_applies({ "base_url" => base_url }, provider, at, VARIABLES) if from_env?(env, "base_url")
        Settings.new(provider:, model:, base_url:, api_key_env: block["api_key_env"],
                     aws_region: block["aws_region"], aws_profile: block["aws_profile"],
                     command_template: block["command_template"], timeout_seconds: block["timeout_seconds"], at:)
      end

      # The adapter class for a provider that has one.
      def self.adapter(provider) = const_get(ADAPTERS.fetch(provider))

      # block as a Hash with only known keys, each well formed, or raises.
      def self.check_block(block, at)
        return {} if block.nil?
        raise ConfigError, "#{at} in #{FILE} must be an object" unless block.is_a?(Hash)

        block.each do |name, value|
          unless KEYS.include?(name)
            raise ConfigError, "#{key(name, at)} isn't a setting: use #{KEYS[0..-2].join(", ")}, or #{KEYS.last}"
          end

          check(key(name, at), name, value)
        end
      end

      # The provider in effect, the block for it, and whether
      # QUAACK_LLM_PROVIDER switched from the block's own provider. A switch
      # gives an empty block. Otherwise it raises unless every key applies.
      def self.for_provider(block, env, at)
        provider = pick(env, block, "provider") || "anthropic"
        return [{}, provider, true] if provider != block.fetch("provider", "anthropic")

        check_applies(block, provider, at)
        [block, provider, false]
      end

      def self.no_model(provider, switched, at)
        return "#{MODEL_ENV} is required when #{PROVIDER_ENV} switches to #{provider}" if switched

        "#{key("model", at)} is required unless the provider is anthropic"
      end

      # Raises unless every key of block applies to provider.
      def self.check_applies(block, provider, at, labels = {})
        block.each_key do |name|
          next if applies?(name, provider)

          raise ConfigError, "#{labels.fetch(name, key(name, at))} doesn't apply to provider #{provider}"
        end
      end

      def self.applies?(name, provider) = ONLY.fetch(name, [provider]).include?(provider)

      # The overriding variable's value if it's set and not empty, else the
      # block's.
      def self.pick(env, block, name)
        variable = VARIABLES.fetch(name)
        value = env[variable]
        value.nil? || value.empty? ? block[name] : check(variable, name, value)
      end

      def self.from_env?(env, name)
        value = env[VARIABLES.fetch(name)]
        !value.nil? && !value.empty?
      end

      # value, if it's good for the key name, or raises, calling it label.
      def self.check(label, name, value)
        ok, problem = CHECKS.fetch(name)
        raise ConfigError, "#{label} #{problem}" unless ok.call(value)
        raise ConfigError, "#{label} #{NOT_ROOT}" if name == "base_url" && ENDPOINT.match?(value)

        value
      end

      def self.key(name, at) = "#{at}.#{name} in #{FILE}"

      def self.command_template?(value)
        return false unless value.is_a?(Array) && value.any? && value.all? { it.is_a?(String) && !it.empty? }

        value.any? { it.include?("{prompt_file}") } && value.any? { it.include?("{model}") }
      end

      private_class_method :check_block, :for_provider, :no_model, :check_applies, :applies?, :pick, :from_env?,
                           :check, :key, :command_template?
    end
  end
end

require_relative "llm/error"
require_relative "llm/client"
require_relative "llm/providers"
require_relative "llm/router"
require_relative "llm/copilot_cli_adapter"
