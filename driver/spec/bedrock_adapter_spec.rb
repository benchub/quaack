# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/llm"
require_relative "support/aws_credentials"
require_relative "support/fake_bedrock"
require_relative "support/llm_client_examples"

# The bedrock adapter behind LLM::Client: Anthropic models on AWS Bedrock,
# through the anthropic gem's BedrockClient. The behavior every adapter
# shares is in support/llm_client_examples.rb.
#
# Every example runs with the AWS environment emptied (see AWSCredentials),
# so no credentials, region, or profile of this machine's is found, and the
# SDK's credential chain never tries the EC2 metadata endpoint.
RSpec.describe "the bedrock adapter" do
  include AWSCredentials

  around { |example| without_aws_credentials { |dir| (@aws_dir = dir) && example.run } }

  it_behaves_like "an LLM client" do
    let(:fake) { FakeBedrock.new }
  end

  let(:burndown) { Quaack::Driver::Burndown.new }
  let(:fake) { FakeBedrock.new }
  let(:client) { fake.client(burndown: burndown) }
  let(:messages) { [{ role: "user", content: "Propose indexes for this shape." }] }
  let(:schema) do
    { type: "object", properties: { ddl: { type: "array", items: { type: "string" } } }, required: ["ddl"],
      additionalProperties: false }
  end

  def ask(step = "llm-index-ideas", **)
    client.ask(step: step, messages: messages, max_tokens: 1000, **)
  end

  # The LLM::Error an ask raises. Fails the spec if it raises nothing.
  def ask_error(step = "llm-index-ideas", **)
    ask(step, **)
    raise "expected an LLM::Error for step #{step}, but the ask succeeded"
  rescue Quaack::Driver::LLM::Error => e
    e
  end

  # A client that finds its credentials the way the driver's does: no keys
  # given, only the settings and the environment.
  def build(settings = FakeBedrock.settings)
    Quaack::Driver::LLM::Client.new(settings:, burndown:, transport: fake)
  end

  def ask_with(client) = client.ask(step: "llm-rewrites", messages: messages, max_tokens: 10)

  # The SigV4 scope an authorization header names: access key ID, region,
  # and service.
  def scope(auth) = auth.match(%r{\AAWS4-HMAC-SHA256 Credential=([^/]+)/\d{8}/([^/]+)/([^/]+)/aws4_request, })&.captures

  def invoke_url(region, model = FakeBedrock::MODEL)
    "https://bedrock-runtime.#{region}.amazonaws.com/model/#{model}/invoke"
  end

  def no_credentials
    "llm_auth: no AWS credentials: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, name a profile in " \
      "llm.aws_profile in ~/.quaack/driver.json or AWS_PROFILE, or set AWS_BEARER_TOKEN_BEDROCK"
  end

  def no_region
    "no AWS region for Bedrock: set llm.aws_region in ~/.quaack/driver.json, AWS_REGION, or a region in the " \
      "AWS profile"
  end

  describe "the request" do
    it "goes to the model's invoke URL in the settings' region, signed with SigV4 for bedrock" do
      fake.reply("llm-rewrites", "ok")
      ask("llm-rewrites")

      expect(fake.asks.map(&:url)).to eq([invoke_url("us-west-2")])
      expect(fake.auths.map { scope(it) }).to eq([[FakeBedrock::ACCESS_KEY, "us-west-2", "bedrock"]])
    end

    it "sends the system prompt, messages, max_tokens, and Bedrock's API version, with the model in the URL" do
      fake.reply("llm-rewrites", "ok")
      client.ask(step: "llm-rewrites", system: "You rewrite SQL.", messages: messages, max_tokens: 321)

      expect(fake.asks.map(&:body)).to eq([{ max_tokens: 321, system: "You rewrite SQL.", messages: messages,
                                             anthropic_version: "bedrock-2023-05-31" }])
    end

    it "asks for structured output with the schema" do
      fake.reply("llm-index-ideas", { "ddl" => [] })

      expect(ask(schema: schema)).to eq("ddl" => [])
      expect(fake.asks.first.body[:output_config])
        .to eq(format: { type: "json_schema", schema: JSON.parse(JSON.generate(schema), symbolize_names: true) })
    end

    it "signs every attempt, retries included" do
      fake.error("llm-rewrites", status: 503).reply("llm-rewrites", "ok")

      expect(ask("llm-rewrites")).to eq("ok")
      expect(fake.auths.map { scope(it) }).to eq([[FakeBedrock::ACCESS_KEY, "us-west-2", "bedrock"]] * 2)
    end

    it "goes to the settings' base URL when there is one" do
      fake.reply("llm-rewrites", "ok")
      settings = FakeBedrock.settings("base_url" => "https://bedrock.example.com")
      fake.client(burndown:, settings:).ask(step: "llm-rewrites", messages: messages, max_tokens: 10)

      expect(fake.asks.map(&:url)).to eq(["https://bedrock.example.com/model/#{FakeBedrock::MODEL}/invoke"])
    end

    # The README says so: the gem reads it, and QUAACK passes it through.
    it "goes to ANTHROPIC_BEDROCK_BASE_URL when the settings have no base URL" do
      fake.reply("llm-rewrites", "ok")
      with_env("ANTHROPIC_BEDROCK_BASE_URL" => "https://bedrock-env.example.com") { ask("llm-rewrites") }

      expect(fake.asks.map(&:url)).to eq(["https://bedrock-env.example.com/model/#{FakeBedrock::MODEL}/invoke"])
    end
  end

  describe "the credentials" do
    it "come from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY" do
      ENV["AWS_ACCESS_KEY_ID"] = "AKIAQUAACKSPECENV001"
      ENV["AWS_SECRET_ACCESS_KEY"] = "SENTINEL-ENV-SECRET"
      fake.reply("llm-rewrites", "ok")
      ask_with(build)

      expect(fake.auths.map { scope(it) }).to eq([%w[AKIAQUAACKSPECENV001 us-west-2 bedrock]])
      expect(fake.auths.join).not_to include("SENTINEL")
    end

    it "carry the session token of temporary credentials, such as SSO's or an assumed role's" do
      ENV["AWS_ACCESS_KEY_ID"] = "ASIAQUAACKSPECTEMP01"
      ENV["AWS_SECRET_ACCESS_KEY"] = "s"
      ENV["AWS_SESSION_TOKEN"] = "fake-session-token"
      fake.reply("llm-rewrites", "ok")
      ask_with(build)

      expect(fake.auths.map { scope(it) }).to eq([%w[ASIAQUAACKSPECTEMP01 us-west-2 bedrock]])
      expect(fake.session_tokens).to eq(["fake-session-token"])
      expect(fake.auths.first).to include("x-amz-security-token")
    end

    it "come from the profile llm.aws_profile names, over the default one" do
      write_aws_profile(@aws_dir, "default", "AKIAQUAACKSPECDEFLT1", "s")
      write_aws_profile(@aws_dir, "quaack-spec", "AKIAQUAACKSPECNAMED1", "s")
      fake.reply("llm-rewrites", "ok")
      ask_with(build(FakeBedrock.settings("aws_profile" => "quaack-spec")))

      expect(fake.auths.map { scope(it) }).to eq([%w[AKIAQUAACKSPECNAMED1 us-west-2 bedrock]])
    end

    it "come from the profile AWS_PROFILE names, through the AWS SDK's own chain" do
      write_aws_profile(@aws_dir, "default", "AKIAQUAACKSPECDEFLT1", "s")
      write_aws_profile(@aws_dir, "quaack-env", "AKIAQUAACKSPECENVPR1", "s")
      ENV["AWS_PROFILE"] = "quaack-env"
      fake.reply("llm-rewrites", "ok")
      ask_with(build)

      expect(fake.auths.map { scope(it) }).to eq([%w[AKIAQUAACKSPECENVPR1 us-west-2 bedrock]])
    end

    it "fail with llm_auth before any attempt when the chain finds none" do
      expect { build }.to raise_error(Quaack::Driver::LLM::Error, no_credentials)
      expect(fake.asks).to eq([])
      expect(burndown.llm_calls).to eq({})
    end

    it "fail with llm_auth before any attempt when llm.aws_profile names a profile that isn't there" do
      write_aws_profile(@aws_dir, "default", "AKIAQUAACKSPECDEFLT1", "s")

      expect { build(FakeBedrock.settings("aws_profile" => "quaack-missing")) }
        .to raise_error(Quaack::Driver::LLM::Error, no_credentials)
      expect(burndown.llm_calls).to eq({})
    end

    it "fail with llm_auth, quoting nothing, when the profile's credentials can't be loaded" do
      write_aws_config(@aws_dir, "profile quaack-broken", "credential_process = /nonexistent/SENTINEL-PATH")

      expect { build(FakeBedrock.settings("aws_profile" => "quaack-broken")) }
        .to raise_error(Quaack::Driver::LLM::Error, "llm_auth: the AWS credentials couldn't be loaded") { |e|
          expect(e.cause).to be_nil
        }
      expect(burndown.llm_calls).to eq({})
    end

    it "fail with llm_auth before any attempt when the keys found aren't set, such as an empty secret" do
      expect { fake.client(burndown:, api_key: "") }.to raise_error(Quaack::Driver::LLM::Error, no_credentials)
      expect(fake.asks).to eq([])
      expect(burndown.llm_calls).to eq({})
    end

    it "fail with llm_auth on credentials AWS refuses, without quoting its message or retrying" do
      fake.error("llm-index-ideas", status: 403, message: "SENTINEL-AWS-MESSAGE")

      e = ask_error

      expect(e.message).to eq("llm_auth: AWS refused the credentials (403) " \
                              "[step llm-index-ideas, max_tokens 1000, system 0 chars, messages: user 31]")
      expect(e.cause).to be_nil
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 1)
    end

    describe "a Bedrock API key in AWS_BEARER_TOKEN_BEDROCK" do
      it "is sent as a bearer token, over the AWS chain" do
        ENV["AWS_BEARER_TOKEN_BEDROCK"] = "SENTINEL-BEDROCK-KEY"
        ENV["AWS_ACCESS_KEY_ID"] = "AKIAQUAACKSPECENV001"
        ENV["AWS_SECRET_ACCESS_KEY"] = "s"
        fake.reply("llm-rewrites", "ok")
        ask_with(build)

        expect(fake.auths).to eq(["Bearer SENTINEL-BEDROCK-KEY"])
        expect(fake.asks.map(&:url)).to eq([invoke_url("us-west-2")])
      end

      it "goes to the region AWS_REGION names when the settings name none" do
        ENV["AWS_BEARER_TOKEN_BEDROCK"] = "k"
        ENV["AWS_REGION"] = "eu-west-3"
        fake.reply("llm-rewrites", "ok")
        ask_with(build(FakeBedrock.settings.with(aws_region: nil)))

        expect(fake.asks.map(&:url)).to eq([invoke_url("eu-west-3")])
      end

      it "fails with llm_auth before any attempt when it's set but empty" do
        ENV["AWS_BEARER_TOKEN_BEDROCK"] = ""

        expect { build }
          .to raise_error(Quaack::Driver::LLM::Error, "llm_auth: AWS_BEARER_TOKEN_BEDROCK is set but empty")
        expect(burndown.llm_calls).to eq({})
      end

      it "can't be used with llm.aws_profile, which names other credentials" do
        ENV["AWS_BEARER_TOKEN_BEDROCK"] = "SENTINEL-BEDROCK-KEY"

        expect { build(FakeBedrock.settings("aws_profile" => "quaack-spec")) }
          .to raise_error(Quaack::Driver::LLM::ConfigError,
                          "llm.aws_profile in ~/.quaack/driver.json can't be used while AWS_BEARER_TOKEN_BEDROCK " \
                          "is set: unset one")
      end

      %w[AWS_REGION AWS_DEFAULT_REGION].each do |name|
        it "refuses a #{name} that isn't a region, naming the variable and not the value" do
          ENV["AWS_BEARER_TOKEN_BEDROCK"] = "k"
          ENV[name] = "SENTINEL us east 1"

          expect { build(FakeBedrock.settings.with(aws_region: nil)) }
            .to raise_error(Quaack::Driver::LLM::ConfigError, "#{name} must be an AWS region, such as us-east-1")
        end
      end

      it "needs a region, unless there's a base URL" do
        ENV["AWS_BEARER_TOKEN_BEDROCK"] = "k"
        regionless = FakeBedrock.settings.with(aws_region: nil)

        expect { build(regionless) }.to raise_error(Quaack::Driver::LLM::ConfigError, no_region)

        fake.reply("llm-rewrites", "ok")
        ask_with(build(regionless.with(base_url: "https://bedrock.example.com")))
        expect(fake.asks.map(&:url)).to eq(["https://bedrock.example.com/model/#{FakeBedrock::MODEL}/invoke"])
      end
    end
  end

  describe "the region" do
    before do
      ENV["AWS_ACCESS_KEY_ID"] = "AKIAQUAACKSPECENV001"
      ENV["AWS_SECRET_ACCESS_KEY"] = "s"
    end

    let(:regionless) { FakeBedrock.settings.with(aws_region: nil) }

    it "is llm.aws_region, over AWS_REGION" do
      ENV["AWS_REGION"] = "eu-west-3"
      fake.reply("llm-rewrites", "ok")
      ask_with(build)

      expect(fake.asks.map(&:url)).to eq([invoke_url("us-west-2")])
      expect(fake.auths.map { scope(it)[1] }).to eq(["us-west-2"])
    end

    it "is AWS_REGION when the settings name none" do
      ENV["AWS_REGION"] = "eu-west-3"
      fake.reply("llm-rewrites", "ok")
      ask_with(build(regionless))

      expect(fake.asks.map(&:url)).to eq([invoke_url("eu-west-3")])
      expect(fake.auths.map { scope(it)[1] }).to eq(["eu-west-3"])
    end

    %w[AWS_REGION AWS_DEFAULT_REGION].each do |name|
      it "refuses a #{name} that isn't a region, naming the variable and not the value" do
        ENV[name] = "SENTINEL us east 1"

        expect { build(regionless) }
          .to raise_error(Quaack::Driver::LLM::ConfigError, "#{name} must be an AWS region, such as us-east-1")
        expect(burndown.llm_calls).to eq({})
      end
    end

    it "is AWS_DEFAULT_REGION when the settings and AWS_REGION name none" do
      ENV["AWS_DEFAULT_REGION"] = "eu-west-3"
      fake.reply("llm-rewrites", "ok")
      ask_with(build(regionless))

      expect(fake.asks.map(&:url)).to eq([invoke_url("eu-west-3")])
    end

    it "takes llm.aws_region without checking AWS_REGION, which it overrides" do
      ENV["AWS_REGION"] = "not a region"
      fake.reply("llm-rewrites", "ok")
      ask_with(build)

      expect(fake.asks.map(&:url)).to eq([invoke_url("us-west-2")])
    end

    it "is the profile's region when neither names one" do
      write_aws_config(@aws_dir, "profile quaack-regional", "region = ap-southeast-2")
      write_aws_profile(@aws_dir, "quaack-regional", "AKIAQUAACKSPECREGN01", "s")
      fake.reply("llm-rewrites", "ok")
      ask_with(build(regionless.with(aws_profile: "quaack-regional")))

      expect(fake.asks.map(&:url)).to eq([invoke_url("ap-southeast-2")])
    end

    it "is required: with none anywhere, it's a usage error before any attempt" do
      expect { build(regionless) }.to raise_error(Quaack::Driver::LLM::ConfigError, no_region)
      expect(burndown.llm_calls).to eq({})
    end
  end

  describe "the build-time messages for an llms entry" do
    def entry(block = {})
      block = { "provider" => "bedrock", "model" => FakeBedrock::MODEL, **block }
      Quaack::Driver::LLM.settings(block, env: {}, at: "llms[2]")
    end

    it "name the entry's aws_profile when there are no credentials" do
      expect { build(entry("aws_region" => FakeBedrock::REGION)) }
        .to raise_error(Quaack::Driver::LLM::Error,
                        "llm_auth: no AWS credentials: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, name a " \
                        "profile in llms[2].aws_profile in ~/.quaack/driver.json or AWS_PROFILE, or set " \
                        "AWS_BEARER_TOKEN_BEDROCK")
    end

    it "name the entry's aws_region when there's no region" do
      ENV["AWS_ACCESS_KEY_ID"] = "AKIAQUAACKSPECENV001"
      ENV["AWS_SECRET_ACCESS_KEY"] = "s"

      expect { build(entry) }
        .to raise_error(Quaack::Driver::LLM::ConfigError,
                        "no AWS region for Bedrock: set llms[2].aws_region in ~/.quaack/driver.json, AWS_REGION, " \
                        "or a region in the AWS profile")
    end

    it "name the entry's aws_region when a Bedrock API key has no region" do
      ENV["AWS_BEARER_TOKEN_BEDROCK"] = "k"

      expect { build(entry) }
        .to raise_error(Quaack::Driver::LLM::ConfigError,
                        "no AWS region for Bedrock: set llms[2].aws_region in ~/.quaack/driver.json, AWS_REGION, " \
                        "or a region in the AWS profile")
    end

    it "name the entry's aws_profile when it's set beside a Bedrock API key" do
      ENV["AWS_BEARER_TOKEN_BEDROCK"] = "k"

      expect { build(entry("aws_region" => FakeBedrock::REGION, "aws_profile" => "quaack-spec")) }
        .to raise_error(Quaack::Driver::LLM::ConfigError,
                        "llms[2].aws_profile in ~/.quaack/driver.json can't be used while " \
                        "AWS_BEARER_TOKEN_BEDROCK is set: unset one")
    end
  end

  describe "a client with no transport, which would call the real API" do
    it "can't be built while specs run" do
      expect { Quaack::Driver::LLM::Client.new(settings: FakeBedrock.settings, burndown:) }
        .to raise_error(Quaack::Driver::LLM::RealClientInSpecs)
    end

    # With the opt-in, the client is built and signs its request, and the
    # spec-time network guard stops it at the gem's HTTP requester. The base
    # URL is a closed local port, so if the guard were missing the request
    # still couldn't reach AWS.
    it "is stopped by the network guard at the gem's requester" do
      ENV["AWS_ACCESS_KEY_ID"] = "AKIAQUAACKSPECENV001"
      ENV["AWS_SECRET_ACCESS_KEY"] = "s"
      settings = FakeBedrock.settings("base_url" => "http://127.0.0.1:9")
      with_env("QUAACK_ALLOW_REAL_LLM" => "1") do
        NoNetwork.always_refuse do
          real = Quaack::Driver::LLM::Client.new(settings:, burndown:, max_retries: 0)

          expect { real.ask(step: "llm-rewrites", messages: messages, max_tokens: 10) }.to raise_error(NoNetwork::Refused)
        end
      end
    end
  end
end

# The root spec/support/no_network.rb stops the anthropic gem's HTTP
# requester, which Anthropic::BedrockClient sends through too, so a spec
# using that client directly can't reach AWS either. The client points at a
# closed local port, so if the guard were missing the request still couldn't
# reach AWS.
RSpec.describe "the spec-time network guard, for Bedrock" do
  include AWSCredentials

  def create(client)
    client.messages.create(model: "m", max_tokens: 10, messages: [{ role: "user", content: "hi" }])
  end

  let(:client) do
    Anthropic::BedrockClient.new(aws_region: "us-west-2", aws_access_key: "AKIAQUAACKSPECFAKE01",
                                 aws_secret_key: "s", base_url: "http://127.0.0.1:9", max_retries: 0)
  end

  # So the gem reads no AWS file or variable of this machine's.
  around { |example| without_aws_credentials { example.run } }

  it "refuses a request that would reach the network from the gem's own Bedrock client" do
    expect { create(client) }.to raise_error(NoNetwork::Refused, /QUAACK_ALLOW_REAL_LLM/)
  end

  # After the block, the opt-in lets the request out, to the closed port.
  it "refuses it even with the opt-in, inside NoNetwork.always_refuse, and only there" do
    with_env("QUAACK_ALLOW_REAL_LLM" => "1") do
      NoNetwork.always_refuse { expect { create(client) }.to raise_error(NoNetwork::Refused) }
      expect { create(client) }.to raise_error(Anthropic::Errors::APIConnectionError)
    end
  end
end
