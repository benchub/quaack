# frozen_string_literal: true

require "anthropic"
require "openai"

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
