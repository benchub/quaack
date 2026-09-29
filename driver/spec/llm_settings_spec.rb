# frozen_string_literal: true

require "quaack/driver/llm"

# The llm block of ~/.quaack/driver.json, with its environment overrides.
RSpec.describe "Quaack::Driver::LLM.settings" do
  def settings(block = nil, env: {}) = Quaack::Driver::LLM.settings(block, env:)

  # The ConfigError settings raises. Fails the spec if it raises nothing.
  def config_error(block, env: {})
    settings(block, env:)
    raise "expected an LLM::ConfigError, but settings succeeded"
  rescue Quaack::Driver::LLM::ConfigError => e
    e
  end

  def fields(result) = result.to_h

  describe "with no llm block" do
    it "is Anthropic with claude-opus-5-5, the gem's own base URL, and no key variable" do
      expect(fields(settings)).to eq(provider: "anthropic", model: "claude-opus-5-5", base_url: nil,
                                     api_key_env: nil)
    end

    it "is the same for an empty block" do
      expect(fields(settings({}))).to eq(fields(settings))
    end
  end

  describe "the block" do
    it "takes each of its keys" do
      block = { "provider" => "anthropic", "model" => "claude-sonnet-5-5", "base_url" => "https://llm.example.com",
                "api_key_env" => "MY_ANTHROPIC_KEY" }

      expect(fields(settings(block))).to eq(provider: "anthropic", model: "claude-sonnet-5-5",
                                            base_url: "https://llm.example.com", api_key_env: "MY_ANTHROPIC_KEY")
    end

    it "takes an http base URL, for a local server" do
      expect(settings({ "base_url" => "http://localhost:11434/v1" }).base_url).to eq("http://localhost:11434/v1")
    end
  end

  describe "the environment" do
    let(:block) { { "model" => "claude-from-config", "base_url" => "https://config.example.com" } }

    it "takes QUAACK_MODEL over the block's model and the default" do
      env = { "QUAACK_MODEL" => "claude-from-env" }

      expect(settings(block, env:).model).to eq("claude-from-env")
      expect(settings(nil, env:).model).to eq("claude-from-env")
    end

    it "takes QUAACK_LLM_BASE_URL over the block's base_url" do
      env = { "QUAACK_LLM_BASE_URL" => "https://env.example.com" }

      expect(settings(block, env:).base_url).to eq("https://env.example.com")
      expect(settings(nil, env:).base_url).to eq("https://env.example.com")
    end

    it "takes QUAACK_LLM_PROVIDER over the block's provider" do
      env = { "QUAACK_LLM_PROVIDER" => "anthropic" }
      block = { "provider" => "openai_compatible", "model" => "m" }

      expect(settings(block, env:).provider).to eq("anthropic")
    end

    it "counts an empty variable as unset" do
      env = { "QUAACK_MODEL" => "", "QUAACK_LLM_BASE_URL" => "", "QUAACK_LLM_PROVIDER" => "" }

      expect(fields(settings(block, env:))).to eq(provider: "anthropic", model: "claude-from-config",
                                                  base_url: "https://config.example.com", api_key_env: nil)
    end

    it "reads the process environment when no env is given" do
      with_env("QUAACK_MODEL" => "claude-from-process") do
        expect(Quaack::Driver::LLM.settings.model).to eq("claude-from-process")
      end
    end
  end

  describe "a bad block" do
    # Each fails naming the key, and never the value, which might be a key
    # pasted in the wrong place.
    {
      "a block that isn't an object" => [["SENTINEL-VALUE"], "llm in ~/.quaack/driver.json must be an object"],
      "an unknown key" => [{ "api_key" => "SENTINEL-VALUE" }, "llm.api_key in ~/.quaack/driver.json isn't a " \
                                                              "setting: use provider, model, base_url, or api_key_env"],
      "an unknown provider" => [{ "provider" => "SENTINEL-VALUE" },
                                "llm.provider in ~/.quaack/driver.json must be anthropic or openai_compatible"],
      "a provider that isn't a string" => [{ "provider" => ["SENTINEL-VALUE"] },
                                           "llm.provider in ~/.quaack/driver.json must be anthropic or " \
                                           "openai_compatible"],
      "an empty model" => [{ "model" => "" }, "llm.model in ~/.quaack/driver.json must be a non-empty string"],
      "a model that isn't a string" => [{ "model" => 5 }, "llm.model in ~/.quaack/driver.json must be a " \
                                                          "non-empty string"],
      "a model with a line break" => [{ "model" => "SENTINEL-VALUE\nx" },
                                      "llm.model in ~/.quaack/driver.json must be a non-empty string"],
      "a base_url that isn't http or https" => [{ "base_url" => "ftp://SENTINEL-VALUE" },
                                                "llm.base_url in ~/.quaack/driver.json must be an http or https URL"],
      "a base_url with a space" => [{ "base_url" => "https://a b/SENTINEL-VALUE" },
                                    "llm.base_url in ~/.quaack/driver.json must be an http or https URL"],
      "an api_key_env that holds a key, not a name" => [{ "api_key_env" => "sk-ant-SENTINEL-VALUE" },
                                                        "llm.api_key_env in ~/.quaack/driver.json must be the " \
                                                        "name of an environment variable"],
      "an empty api_key_env" => [{ "api_key_env" => "" }, "llm.api_key_env in ~/.quaack/driver.json must be the " \
                                                          "name of an environment variable"]
    }.each do |what, (block, message)|
      it "fails on #{what}, naming the key and not the value" do
        e = config_error(block)

        expect(e.message).to eq(message)
        expect(e.message).not_to include("SENTINEL")
      end
    end

    it "fails on a bad QUAACK_LLM_PROVIDER, naming the variable and not its value" do
      e = config_error(nil, env: { "QUAACK_LLM_PROVIDER" => "SENTINEL-VALUE" })

      expect(e.message).to eq("QUAACK_LLM_PROVIDER must be anthropic or openai_compatible")
    end

    it "fails on a bad QUAACK_LLM_BASE_URL, naming the variable and not its value" do
      e = config_error(nil, env: { "QUAACK_LLM_BASE_URL" => "SENTINEL-VALUE" })

      expect(e.message).to eq("QUAACK_LLM_BASE_URL must be an http or https URL")
    end

    it "fails on a QUAACK_MODEL with a line break, naming the variable and not its value" do
      e = config_error(nil, env: { "QUAACK_MODEL" => "SENTINEL-VALUE\n" })

      expect(e.message).to eq("QUAACK_MODEL must be a non-empty string")
    end

    it "checks a block value even when the environment overrides it" do
      e = config_error({ "base_url" => "SENTINEL-VALUE" }, env: { "QUAACK_LLM_BASE_URL" => "https://env.example.com" })

      expect(e.message).to eq("llm.base_url in ~/.quaack/driver.json must be an http or https URL")
    end
  end

  describe "a provider other than anthropic" do
    it "requires a model, since it has no default" do
      e = config_error({ "provider" => "openai_compatible" })

      expect(e.message).to eq("llm.model in ~/.quaack/driver.json is required unless the provider is anthropic")
    end

    it "takes the model from QUAACK_MODEL too" do
      result = settings({ "provider" => "openai_compatible" }, env: { "QUAACK_MODEL" => "llama-3.3-70b" })

      expect(result.model).to eq("llama-3.3-70b")
    end

    it "takes openai_compatible with a model, a base URL, and a key variable" do
      block = { "provider" => "openai_compatible", "model" => "llama-3.3-70b-versatile",
                "base_url" => "https://api.groq.com/openai/v1", "api_key_env" => "GROQ_API_KEY" }

      expect(fields(settings(block))).to eq(provider: "openai_compatible", model: "llama-3.3-70b-versatile",
                                            base_url: "https://api.groq.com/openai/v1", api_key_env: "GROQ_API_KEY")
    end

    it "has an adapter for every provider it takes" do
      expect(Quaack::Driver::LLM::PROVIDERS.map { Quaack::Driver::LLM.adapter(it).name.split("::").last })
        .to eq(%w[AnthropicAdapter OpenAICompatibleAdapter])
    end
  end
end
