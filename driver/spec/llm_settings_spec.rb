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
                                     api_key_env: nil, aws_region: nil, aws_profile: nil,
                                     command_template: nil, timeout_seconds: nil)
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
                                            base_url: "https://llm.example.com", api_key_env: "MY_ANTHROPIC_KEY",
                                            aws_region: nil, aws_profile: nil, command_template: nil,
                                            timeout_seconds: nil)
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
                                                  base_url: "https://config.example.com", api_key_env: nil,
                                                  aws_region: nil, aws_profile: nil, command_template: nil,
                                                  timeout_seconds: nil)
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
                                                              "setting: use provider, model, base_url, api_key_env, " \
                                                              "aws_region, aws_profile, command_template, or " \
                                                              "timeout_seconds"],
      "an unknown provider" => [{ "provider" => "SENTINEL-VALUE" },
                                "llm.provider in ~/.quaack/driver.json must be anthropic, openai_compatible, " \
                                "bedrock, or copilot_cli"],
      "a provider that isn't a string" => [{ "provider" => ["SENTINEL-VALUE"] },
                                           "llm.provider in ~/.quaack/driver.json must be anthropic, " \
                                           "openai_compatible, bedrock, or copilot_cli"],
      "an empty model" => [{ "model" => "" }, "llm.model in ~/.quaack/driver.json must be a non-empty string"],
      "a model that isn't a string" => [{ "model" => 5 }, "llm.model in ~/.quaack/driver.json must be a " \
                                                          "non-empty string"],
      "a model with a line break" => [{ "model" => "SENTINEL-VALUE\nx" },
                                      "llm.model in ~/.quaack/driver.json must be a non-empty string"],
      "a base_url that isn't http or https" => [{ "base_url" => "ftp://SENTINEL-VALUE" },
                                                "llm.base_url in ~/.quaack/driver.json must be an http or https URL"],
      "a base_url with a space" => [{ "base_url" => "https://a b/SENTINEL-VALUE" },
                                    "llm.base_url in ~/.quaack/driver.json must be an http or https URL"],
      "a base_url that's a chat completions endpoint" => [
        { "provider" => "openai_compatible", "model" => "m",
          "base_url" => "https://api.groq.com/openai/v1/chat/completions" },
        "llm.base_url in ~/.quaack/driver.json must be the API root, such as https://api.groq.com/openai/v1, " \
        "without /chat/completions"
      ],
      "a base_url that's a chat completions endpoint, with a slash" => [
        { "provider" => "openai_compatible", "model" => "m",
          "base_url" => "https://SENTINEL-VALUE/v1/chat/completions/" },
        "llm.base_url in ~/.quaack/driver.json must be the API root, such as https://api.groq.com/openai/v1, " \
        "without /chat/completions"
      ],
      "an api_key_env that holds a key, not a name" => [{ "api_key_env" => "sk-ant-SENTINEL-VALUE" },
                                                        "llm.api_key_env in ~/.quaack/driver.json must be the " \
                                                        "name of an environment variable"],
      "an empty api_key_env" => [{ "api_key_env" => "" }, "llm.api_key_env in ~/.quaack/driver.json must be the " \
                                                          "name of an environment variable"],
      "an aws_region that isn't a region" => [{ "provider" => "bedrock", "model" => "m",
                                                "aws_region" => "SENTINEL-VALUE" },
                                              "llm.aws_region in ~/.quaack/driver.json must be an AWS region, " \
                                              "such as us-east-1"],
      "an aws_region that isn't a string" => [{ "provider" => "bedrock", "model" => "m", "aws_region" => 1 },
                                              "llm.aws_region in ~/.quaack/driver.json must be an AWS region, " \
                                              "such as us-east-1"],
      "an empty aws_profile" => [{ "provider" => "bedrock", "model" => "m", "aws_profile" => "" },
                                 "llm.aws_profile in ~/.quaack/driver.json must be the name of an AWS profile"],
      "an aws_profile with a line break" => [{ "provider" => "bedrock", "model" => "m",
                                               "aws_profile" => "SENTINEL-VALUE\nx" },
                                             "llm.aws_profile in ~/.quaack/driver.json must be the name of an AWS " \
                                             "profile"],
      "a command_template that isn't an array" => [{ "provider" => "copilot_cli", "command_template" => "copilot" },
                                                   "llm.command_template in ~/.quaack/driver.json must be an argv " \
                                                   "array with {prompt_file} and {model} placeholders"],
      "a command_template with a bad arg" => [{ "provider" => "copilot_cli",
                                                "command_template" => ["copilot", 1, "{prompt_file}", "{model}"] },
                                              "llm.command_template in ~/.quaack/driver.json must be an argv array " \
                                              "with {prompt_file} and {model} placeholders"],
      "a command_template without the prompt placeholder" => [
        { "provider" => "copilot_cli", "command_template" => ["copilot", "{model}"] },
        "llm.command_template in ~/.quaack/driver.json must be an argv array with {prompt_file} and {model} " \
        "placeholders"
      ],
      "a command_template without the model placeholder" => [
        { "provider" => "copilot_cli", "command_template" => ["copilot", "{prompt_file}"] },
        "llm.command_template in ~/.quaack/driver.json must be an argv array with {prompt_file} and {model} " \
        "placeholders"
      ],
      "a non-positive timeout" => [{ "provider" => "copilot_cli", "timeout_seconds" => 0 },
                                   "llm.timeout_seconds in ~/.quaack/driver.json must be a positive number"],
      "a timeout that isn't numeric" => [{ "provider" => "copilot_cli", "timeout_seconds" => "SENTINEL-VALUE" },
                                         "llm.timeout_seconds in ~/.quaack/driver.json must be a positive number"]
    }.each do |what, (block, message)|
      it "fails on #{what}, naming the key and not the value" do
        e = config_error(block)

        expect(e.message).to eq(message)
        expect(e.message).not_to include("SENTINEL")
      end
    end

    it "fails on a bad QUAACK_LLM_PROVIDER, naming the variable and not its value" do
      e = config_error(nil, env: { "QUAACK_LLM_PROVIDER" => "SENTINEL-VALUE" })

      expect(e.message).to eq("QUAACK_LLM_PROVIDER must be anthropic, openai_compatible, bedrock, or copilot_cli")
    end

    it "fails on a bad QUAACK_LLM_BASE_URL, naming the variable and not its value" do
      e = config_error(nil, env: { "QUAACK_LLM_BASE_URL" => "SENTINEL-VALUE" })

      expect(e.message).to eq("QUAACK_LLM_BASE_URL must be an http or https URL")
    end

    it "fails on a QUAACK_MODEL with a line break, naming the variable and not its value" do
      e = config_error(nil, env: { "QUAACK_MODEL" => "SENTINEL-VALUE\n" })

      expect(e.message).to eq("QUAACK_MODEL must be a non-empty string")
    end

    it "fails on a QUAACK_LLM_BASE_URL that's a chat completions endpoint, naming the variable" do
      e = config_error({ "provider" => "openai_compatible", "model" => "m" },
                       env: { "QUAACK_LLM_BASE_URL" => "https://SENTINEL-VALUE/v1/chat/completions" })

      expect(e.message).to eq("QUAACK_LLM_BASE_URL must be the API root, such as https://api.groq.com/openai/v1, " \
                              "without /chat/completions")
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
                                            base_url: "https://api.groq.com/openai/v1", api_key_env: "GROQ_API_KEY",
                                            aws_region: nil, aws_profile: nil, command_template: nil,
                                            timeout_seconds: nil)
    end

    it "has an adapter for every provider it takes" do
      expect(Quaack::Driver::LLM::PROVIDERS.map { Quaack::Driver::LLM.adapter(it).name.split("::").last })
        .to eq(%w[AnthropicAdapter OpenAICompatibleAdapter BedrockAdapter CopilotCLIAdapter])
    end
  end

  describe "the bedrock provider" do
    let(:block) do
      { "provider" => "bedrock", "model" => "us.anthropic.claude-opus-5-5", "aws_region" => "us-west-2",
        "aws_profile" => "quaack-bedrock", "base_url" => "https://bedrock.example.com" }
    end

    it "takes a model, an AWS region and profile, and a base URL" do
      expect(fields(settings(block))).to eq(provider: "bedrock", model: "us.anthropic.claude-opus-5-5",
                                            base_url: "https://bedrock.example.com", api_key_env: nil,
                                            aws_region: "us-west-2", aws_profile: "quaack-bedrock",
                                            command_template: nil, timeout_seconds: nil)
    end

    it "needs neither the region nor the profile, since the AWS SDK can find them" do
      result = settings({ "provider" => "bedrock", "model" => "anthropic.claude-opus-5-5" })

      expect([result.aws_region, result.aws_profile]).to eq([nil, nil])
    end

    it "takes each region form AWS uses" do
      %w[us-east-1 eu-central-1 ap-southeast-2 us-gov-west-1 ca-west-1].each do |region|
        expect(settings(block.merge("aws_region" => region)).aws_region).to eq(region)
      end
    end

    it "requires a model, since Bedrock's model IDs vary by region and inference profile" do
      e = config_error({ "provider" => "bedrock", "aws_region" => "us-west-2" })

      expect(e.message).to eq("llm.model in ~/.quaack/driver.json is required unless the provider is anthropic")
    end

    it "is picked by QUAACK_LLM_PROVIDER, with the model from QUAACK_MODEL" do
      env = { "QUAACK_LLM_PROVIDER" => "bedrock", "QUAACK_MODEL" => "anthropic.claude-opus-5-5" }

      expect(fields(settings(nil, env:))).to eq(provider: "bedrock", model: "anthropic.claude-opus-5-5",
                                                base_url: nil, api_key_env: nil, aws_region: nil, aws_profile: nil,
                                                command_template: nil, timeout_seconds: nil)
    end

    it "refuses api_key_env, since its credentials come from AWS" do
      e = config_error({ "provider" => "bedrock", "model" => "m", "api_key_env" => "SENTINEL_VALUE" })

      expect(e.message).to eq("llm.api_key_env in ~/.quaack/driver.json doesn't apply to provider bedrock")
    end

    %w[aws_region aws_profile].each do |name|
      it "is the only provider that takes #{name}" do
        value = name == "aws_region" ? "us-west-2" : "SENTINEL-VALUE"
        [{ "provider" => "openai_compatible", "model" => "m" }, {}].each do |base|
          e = config_error(base.merge(name => value))

          provider = base.fetch("provider", "anthropic")
          expect(e.message).to eq("llm.#{name} in ~/.quaack/driver.json doesn't apply to provider #{provider}")
          expect(e.message).not_to include("SENTINEL")
        end
      end
    end

    it "judges which keys apply by the provider QUAACK_LLM_PROVIDER picks" do
      e = config_error(block, env: { "QUAACK_LLM_PROVIDER" => "anthropic" })

      expect(e.message).to eq("llm.aws_region in ~/.quaack/driver.json doesn't apply to provider anthropic")
      expect(settings({ "aws_region" => "us-west-2" }, env: { "QUAACK_LLM_PROVIDER" => "bedrock",
                                                              "QUAACK_MODEL" => "m" }).aws_region)
        .to eq("us-west-2")
    end
  end

  describe "the copilot_cli provider" do
    it "has claude-opus-5.5 as its default model" do
      result = settings({ "provider" => "copilot_cli" })

      expect(fields(result)).to eq(provider: "copilot_cli", model: "claude-opus-5.5", base_url: nil,
                                   api_key_env: nil, aws_region: nil, aws_profile: nil,
                                   command_template: nil, timeout_seconds: nil)
    end

    it "is picked by QUAACK_LLM_PROVIDER, with its default model" do
      result = settings(nil, env: { "QUAACK_LLM_PROVIDER" => "copilot_cli" })

      expect([result.provider, result.model]).to eq(%w[copilot_cli claude-opus-5.5])
    end

    it "refuses QUAACK_LLM_BASE_URL when QUAACK_LLM_PROVIDER picks copilot_cli" do
      e = config_error(nil, env: { "QUAACK_LLM_PROVIDER" => "copilot_cli",
                                   "QUAACK_LLM_BASE_URL" => "https://sentinel.example" })

      expect(e.message).to eq("QUAACK_LLM_BASE_URL doesn't apply to provider copilot_cli")
      expect(e.message).not_to include("sentinel")
    end

    it "refuses a block base_url when QUAACK_LLM_PROVIDER switches to copilot_cli" do
      e = config_error({ "base_url" => "https://sentinel.example" },
                       env: { "QUAACK_LLM_PROVIDER" => "copilot_cli" })

      expect(e.message).to eq("llm.base_url in ~/.quaack/driver.json doesn't apply to provider copilot_cli")
      expect(e.message).not_to include("sentinel")
    end

    it "refuses copilot-only block keys when QUAACK_LLM_PROVIDER switches away" do
      template = ["copilot", "{prompt_file}", "{model}"]
      e = config_error({ "provider" => "copilot_cli", "command_template" => template },
                       env: { "QUAACK_LLM_PROVIDER" => "anthropic" })

      expect(e.message).to eq("llm.command_template in ~/.quaack/driver.json doesn't apply to provider anthropic")
    end

    it "takes its command template and timeout" do
      template = ["/opt/bin/copilot", "--model={model}", "-p", "Read {prompt_file}"]
      result = settings({ "provider" => "copilot_cli", "command_template" => template, "timeout_seconds" => 12.5 })

      expect(result.command_template).to eq(template)
      expect(result.timeout_seconds).to eq(12.5)
    end

    %w[base_url api_key_env aws_region aws_profile].each do |name|
      it "refuses #{name}, which applies to another provider" do
        value = case name
                when "base_url" then "https://example.com"
                when "aws_region" then "us-west-2"
                else "SENTINEL_VALUE"
                end
        e = config_error({ "provider" => "copilot_cli", name => value })

        expect(e.message).to eq("llm.#{name} in ~/.quaack/driver.json doesn't apply to provider copilot_cli")
        expect(e.message).not_to include("SENTINEL")
      end
    end

    %w[anthropic openai_compatible bedrock].each do |provider|
      it "is the only provider that takes command_template and timeout_seconds, not #{provider}" do
        base = { "provider" => provider, "model" => "m" }
        e = config_error(base.merge("command_template" => ["copilot", "{prompt_file}", "{model}"]))

        expect(e.message).to eq("llm.command_template in ~/.quaack/driver.json doesn't apply to provider #{provider}")
      end
    end
  end
end
