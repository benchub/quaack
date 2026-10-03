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
    # ~/.quaack/driver.json, with environment overrides. See `settings`. The
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
      # timeout_seconds are copilot_cli's, nil for its defaults.
      Settings = Data.define(:provider, :model, :base_url, :api_key_env, :aws_region, :aws_profile,
                             :command_template, :timeout_seconds)

      NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      LINE = /\A[^\n\r]*\S[^\n\r]*\z/
      URL = %r{\Ahttps?://[^\s/]+\S*\z}
      # An AWS region's name, such as us-east-1 or us-gov-west-1.
      REGION = /\A[a-z]{2}(-[a-z]+)+-\d+\z/

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
      # provider.
      def self.settings(block = nil, env: ENV)
        block = check_block(block)
        provider = pick(env, block, "provider") || "anthropic"
        check_applies(block, provider)
        model = pick(env, block, "model") || DEFAULT_MODELS[provider]
        model or raise ConfigError, "#{key("model")} is required unless the provider is anthropic"
        base_url = pick(env, block, "base_url")
        check_applies({ "base_url" => base_url }, provider, "base_url" => BASE_URL_ENV) if from_env?(env, "base_url")
        Settings.new(provider:, model:, base_url:, api_key_env: block["api_key_env"],
                     aws_region: block["aws_region"], aws_profile: block["aws_profile"],
                     command_template: block["command_template"], timeout_seconds: block["timeout_seconds"])
      end

      # The adapter class for a provider that has one.
      def self.adapter(provider) = const_get(ADAPTERS.fetch(provider))

      # block as a Hash with only known keys, each well formed, or raises.
      def self.check_block(block)
        return {} if block.nil?
        raise ConfigError, "#{BLOCK} in #{FILE} must be an object" unless block.is_a?(Hash)

        block.each do |name, value|
          unless KEYS.include?(name)
            raise ConfigError, "#{key(name)} isn't a setting: use #{KEYS[0..-2].join(", ")}, or #{KEYS.last}"
          end

          check(key(name), name, value)
        end
      end

      # Raises unless every key of block applies to provider.
      def self.check_applies(block, provider, labels = {})
        block.each_key do |name|
          next if ONLY.fetch(name, [provider]).include?(provider)

          raise ConfigError, "#{labels.fetch(name, key(name))} doesn't apply to provider #{provider}"
        end
      end

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

        value
      end

      def self.key(name) = "#{BLOCK}.#{name} in #{FILE}"

      def self.command_template?(value)
        return false unless value.is_a?(Array) && value.any? && value.all? { it.is_a?(String) && !it.empty? }

        value.any? { it.include?("{prompt_file}") } && value.any? { it.include?("{model}") }
      end

      private_class_method :check_block, :check_applies, :pick, :from_env?, :check, :key, :command_template?
    end
  end
end

require_relative "llm/error"
require_relative "llm/client"
require_relative "llm/anthropic_adapter"
require_relative "llm/openai_compatible_adapter"
require_relative "llm/bedrock_adapter"
require_relative "llm/copilot_cli_adapter"
