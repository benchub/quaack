# frozen_string_literal: true

require "anthropic"

# The root suite shares the driver suite's network guard,
# spec/support/no_network.rb, so no root spec can call the real API either.
# The client points at a closed local port, so if the guard were missing the
# request still couldn't reach the API.
RSpec.describe "the root suite's network guard" do
  it "refuses a request that would reach the network from the gem's own client" do
    client = Anthropic::Client.new(api_key: "k", base_url: "http://127.0.0.1:9", max_retries: 0)

    expect { client.messages.create(model: "m", max_tokens: 10, messages: [{ role: "user", content: "hi" }]) }
      .to raise_error(NoNetwork::Refused, /QUAACK_ALLOW_REAL_LLM/)
  end
end
