# frozen_string_literal: true

require "anthropic"

# spec/support/no_network.rb stops the anthropic gem's HTTP requester, the
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
end
