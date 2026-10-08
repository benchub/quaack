# frozen_string_literal: true

require "anthropic"
require "openai"

# The root suite shares the driver suite's network guard,
# spec/support/no_network.rb, so no root spec can call the real API either.
# The client points at a closed local port, so if the guard were missing the
# request still couldn't reach the API.
RSpec.describe "the root suite's network guard" do
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
    client = Anthropic::Client.new(api_key: "k", base_url: "http://127.0.0.1:9", max_retries: 0)

    expect { client.messages.create(model: "m", max_tokens: 10, messages: [{ role: "user", content: "hi" }]) }
      .to raise_error(NoNetwork::Refused, /QUAACK_ALLOW_REAL_LLM/)
  end

  it "refuses a request that would reach the network from the openai gem's own client" do
    client = OpenAI::Client.new(api_key: "k", base_url: "http://127.0.0.1:9", max_retries: 0)

    expect { client.chat.completions.create(model: "m", messages: [{ role: "user", content: "hi" }]) }
      .to raise_error(NoNetwork::Refused, /QUAACK_ALLOW_REAL_LLM/)
  end
end
