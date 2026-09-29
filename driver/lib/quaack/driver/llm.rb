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
    # ~/.quaack/driver.json, with environment overrides. See `settings`.
    #
    # The driver never holds a production value, so a prompt only ever
    # carries shapes. Client doesn't check that. The callers that build the
    # prompts own it.
    module LLM
      DEFAULT_MODEL = "claude-opus-5-5"

      # Override the llm block's model, provider, and base_url.
      MODEL_ENV = "QUAACK_MODEL"
      PROVIDER_ENV = "QUAACK_LLM_PROVIDER"
      BASE_URL_ENV = "QUAACK_LLM_BASE_URL"

      # Every provider the llm block may name, and the default model of each
      # that has one. Any other needs a model.
      PROVIDERS = %w[anthropic openai_compatible].freeze
      DEFAULT_MODELS = { "anthropic" => DEFAULT_MODEL }.freeze

      # The adapter class for each provider, by constant name under LLM.
      ADAPTERS = { "anthropic" => :AnthropicAdapter, "openai_compatible" => :OpenAICompatibleAdapter }.freeze

      BLOCK = "llm"
      FILE = "~/.quaack/driver.json"

      # A bad llm block or override. The message names the key or the
      # variable, never its value, which might be a key pasted in the wrong
      # place.
      class ConfigError < StandardError; end

      # What an adapter is built from. base_url nil means the provider's own
      # default. api_key_env is the name of the variable that holds the key,
      # or nil for the provider's usual lookup.
      Settings = Data.define(:provider, :model, :base_url, :api_key_env)

      NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      LINE = /\A[^\n\r]*\S[^\n\r]*\z/
      URL = %r{\Ahttps?://[^\s/]+\S*\z}

      # Each key of the block: whether a value is good, and what a bad one
      # is told.
      CHECKS = {
        "provider" => [->(v) { PROVIDERS.include?(v) }, "must be #{PROVIDERS.join(" or ")}"],
        "model" => [->(v) { v.is_a?(String) && LINE.match?(v) }, "must be a non-empty string"],
        "base_url" => [->(v) { v.is_a?(String) && URL.match?(v) }, "must be an http or https URL"],
        "api_key_env" => [->(v) { v.is_a?(String) && NAME.match?(v) }, "must be the name of an environment variable"]
      }.freeze
      KEYS = CHECKS.keys.freeze

      # The variable that overrides each key that has one.
      VARIABLES = { "provider" => PROVIDER_ENV, "model" => MODEL_ENV, "base_url" => BASE_URL_ENV }.freeze

      # The Settings from `block`, the parsed llm block of the driver config
      # (nil when there's none), and env. QUAACK_MODEL, QUAACK_LLM_PROVIDER,
      # and QUAACK_LLM_BASE_URL override the block, and an empty one counts
      # as unset. With neither, it's Anthropic with DEFAULT_MODEL. Raises
      # ConfigError for a bad value.
      def self.settings(block = nil, env: ENV)
        block = check_block(block)
        provider = pick(env, block, "provider") || "anthropic"
        model = pick(env, block, "model") || DEFAULT_MODELS[provider]
        model or raise ConfigError, "#{key("model")} is required unless the provider is anthropic"
        Settings.new(provider:, model:, base_url: pick(env, block, "base_url"), api_key_env: block["api_key_env"])
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

      # The overriding variable's value if it's set and not empty, else the
      # block's.
      def self.pick(env, block, name)
        variable = VARIABLES.fetch(name)
        value = env[variable]
        value.nil? || value.empty? ? block[name] : check(variable, name, value)
      end

      # value, if it's good for the key name, or raises, calling it label.
      def self.check(label, name, value)
        ok, problem = CHECKS.fetch(name)
        raise ConfigError, "#{label} #{problem}" unless ok.call(value)

        value
      end

      def self.key(name) = "#{BLOCK}.#{name} in #{FILE}"

      private_class_method :check_block, :pick, :check, :key
    end
  end
end

require_relative "llm/error"
require_relative "llm/client"
require_relative "llm/anthropic_adapter"
require_relative "llm/openai_compatible_adapter"
