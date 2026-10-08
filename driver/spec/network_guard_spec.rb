# frozen_string_literal: true

require "anthropic"
require "openai"
require "aws-sdk-bedrockruntime"

# The root spec/support/no_network.rb stops the anthropic gem's HTTP requester, the
# one way its requests reach the network, so no spec can call the real API,
# even through Anthropic::Client directly. The client points at a closed
# local port, so if the guard were missing the request still couldn't reach
# the API.
RSpec.describe "the spec-time network guard" do
  def create(client)
    client.messages.create(model: "m", max_tokens: 10, messages: [{ role: "user", content: "hi" }])
  end

  let(:client) { Anthropic::Client.new(api_key: "k", base_url: "http://127.0.0.1:9", max_retries: 0) }

  # The client's constructor reads the anthropic config dir's active_config
  # even with an api_key. Under a HOME whose ~/.config/anthropic would raise
  # on that read, building one still works, so it never reads the real one.
  it "builds the gem's own client without reading the real ~/.config/anthropic" do
    client = NoRealCredentials.with_trapped_home do
      Anthropic::Client.new(api_key: "k", base_url: "http://127.0.0.1:9", max_retries: 0)
    end

    expect(client.base_url.to_s).to start_with("http://127.0.0.1:9")
  end

  it "refuses a request that would reach the network from the gem's own client" do
    expect { create(client) }.to raise_error(NoNetwork::Refused, /QUAACK_ALLOW_REAL_LLM/)
  end

  it "refuses it even when the opt-in is set to something other than 1" do
    with_env("QUAACK_ALLOW_REAL_LLM" => "yes") do
      expect { create(client) }.to raise_error(NoNetwork::Refused)
    end
  end

  # After the block, the opt-in lets the request out, to the closed port.
  it "refuses it even with the opt-in, inside NoNetwork.always_refuse, and only there" do
    with_env("QUAACK_ALLOW_REAL_LLM" => "1") do
      NoNetwork.always_refuse { expect { create(client) }.to raise_error(NoNetwork::Refused) }
      expect { create(client) }.to raise_error(Anthropic::Errors::APIConnectionError)
    end
  end

  # A block that raises still ends the always-refuse, so a later request
  # with the opt-in reaches the closed port.
  it "stops refusing with the opt-in after a block that raises" do
    with_env("QUAACK_ALLOW_REAL_LLM" => "1") do
      expect { NoNetwork.always_refuse { raise "boom" } }.to raise_error(RuntimeError, "boom")
      expect { create(client) }.to raise_error(Anthropic::Errors::APIConnectionError)
    end
  end
end

# The same guard stops the openai gem's HTTP client, the one way the
# OpenAI-compatible adapter's requests reach the network.
RSpec.describe "the spec-time network guard, for the openai gem" do
  def create(client)
    client.chat.completions.create(model: "m", messages: [{ role: "user", content: "hi" }])
  end

  let(:client) { OpenAI::Client.new(api_key: "k", base_url: "http://127.0.0.1:9", max_retries: 0) }

  it "refuses a request that would reach the network from the gem's own client" do
    expect { create(client) }.to raise_error(NoNetwork::Refused, /QUAACK_ALLOW_REAL_LLM/)
  end

  it "refuses it even when the opt-in is set to something other than 1" do
    with_env("QUAACK_ALLOW_REAL_LLM" => "yes") do
      expect { create(client) }.to raise_error(NoNetwork::Refused)
    end
  end

  # After the block, the opt-in lets the request out, to the closed port.
  it "refuses it even with the opt-in, inside NoNetwork.always_refuse, and only there" do
    with_env("QUAACK_ALLOW_REAL_LLM" => "1") do
      NoNetwork.always_refuse { expect { create(client) }.to raise_error(NoNetwork::Refused) }
      expect { create(client) }.to raise_error(OpenAI::Errors::APIConnectionError)
    end
  end
end

# The AWS SDK's credential chain, which the Bedrock adapter uses when it's
# handed no keys, reads ~/.aws/config and ~/.aws/credentials, then asks the
# EC2 metadata endpoint. Under a HOME whose ~/.aws files would raise on that
# read, the chain still finds nothing, so it never reads the real ones, and
# it never builds the metadata provider, so it never reaches 169.254.169.254.
RSpec.describe "the spec-time guard on the AWS SDK's credential chain" do
  # The SDK reads its files once and keeps them, so they're forgotten around
  # each example.
  def forget_aws_files = Aws.instance_variable_set(:@shared_config, nil)

  # The variables that would end the chain before it reads the files.
  around do |example|
    names = %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
               AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
               AWS_CONTAINER_CREDENTIALS_FULL_URI]
    with_env(names.to_h { [it, nil] }) do
      forget_aws_files
      example.run
    ensure
      forget_aws_files
    end
  end

  it "finds no credentials, without reading the real ~/.aws or asking the EC2 metadata endpoint" do
    expect(Aws::InstanceProfileCredentials).not_to receive(:new)

    credentials = NoRealCredentials.with_trapped_home do
      Aws::BedrockRuntime::Client.new(region: "us-east-1").config.credentials
    end

    expect(credentials).to be_nil
  end
end
