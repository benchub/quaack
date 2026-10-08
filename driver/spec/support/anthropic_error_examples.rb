# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/llm"

# The error detail of an adapter on the Anthropic Messages API, which the
# anthropic and bedrock adapters share: only the status and the body's own
# error message, with the adapter's key and any key in base_url's query
# string scrubbed out of it. The base URL can name a gateway or proxy, such
# as LiteLLM, whose body can echo a key or anything else, so the whole body
# and the URL never print.
#
# The including group defines `fake`, a FakeLLM or FakeBedrock, whose
# `client` takes the key as `api_key` and whose class's `settings` takes a
# block such as a base_url.
RSpec.shared_examples "an Anthropic API's error detail" do
  let(:burndown) { Quaack::Driver::Burndown.new }
  let(:messages) { [{ role: "user", content: "Propose indexes for this shape." }] }
  let(:gateway) { "https://gateway.example.test/anthropic?team=quaack&key=SENTINEL-OWN-KEY-SENTINEL-URL" }
  let(:client) do
    fake.client(burndown:, api_key: "SENTINEL-OWN-KEY", settings: fake.class.settings("base_url" => gateway),
                max_retries: 0)
  end

  # The LLM::Error an ask raises. Fails the spec if it raises nothing.
  def gateway_error
    client.ask(step: "llm-index-ideas", messages: messages, max_tokens: 10)
    raise "expected an LLM::Error, but the ask succeeded"
  rescue Quaack::Driver::LLM::Error => e
    e
  end

  # A gateway's body that echoes the keys, the URL, and more, in its
  # message and beside it.
  def echoing_body(status)
    { type: "error", request_id: "SENTINEL-BODY-REQUEST",
      error: { type: "api_error", message: "upstream said no (#{status}) for SENTINEL-OWN-KEY at #{gateway}",
               echoed_headers: { "x-api-key" => "SENTINEL-OWN-KEY" } },
      detail: "SENTINEL-BODY-DETAIL" }
  end

  def without_sizes(message) = message.sub(/ \[step .*\]\z/, "")

  [[400, "llm_bad_request"], [500, "llm_unavailable"]].each do |status, rule|
    it "shows only the status and the body's message, keys scrubbed, from a gateway's #{status}" do
      fake.error_body("llm-index-ideas", status: status, body: echoing_body(status))

      e = gateway_error

      expect(e.rule).to eq(rule)
      expect(without_sizes(e.message))
        .to eq("#{rule}: the API answered #{status}: upstream said no (#{status}) for [key] at " \
               "https://gateway.example.test/anthropic?team=quaack&key=[key]")
      expect(e.cause).to be_nil
      expect(error_text(e)).not_to include("SENTINEL")
    end
  end

  it "shows only the status when the body has no message, never the body or the URL" do
    fake.error_body("llm-index-ideas", status: 400, body: { error: { type: "SENTINEL-TYPE" }, gateway: gateway })
        .error_body("llm-index-ideas", status: 500, body: "<html>SENTINEL-OWN-KEY at #{gateway}</html>")
        .error_body("llm-index-ideas", status: 502, body: { error: { message: ["SENTINEL-NOT-TEXT"] } })
        .error_body("llm-index-ideas", status: 422, body: { error: { message: "" } })

    seen = Array.new(4) { gateway_error }

    expect(seen.map { without_sizes(it.message) })
      .to eq(["llm_bad_request: the API answered 400", "llm_unavailable: the API answered 500",
              "llm_unavailable: the API answered 502", "llm_bad_request: the API answered 422"])
    expect(seen.map { error_text(it) }.join).not_to include("SENTINEL")
    expect(seen.map { error_text(it) }.join).not_to include("gateway.example.test")
  end

  it "scrubs a base_url query value as written and decoded, with ; as a separator too" do
    gateway = "https://gateway.example.test/anthropic?token=SENTINEL%2BENCODED;auth=SENTINEL-AFTER-SEMICOLON"
    client = fake.client(burndown:, settings: fake.class.settings("base_url" => gateway), max_retries: 0)
    echo = "saw SENTINEL%2BENCODED, SENTINEL+ENCODED, and SENTINEL-AFTER-SEMICOLON"
    fake.error_body("llm-index-ideas", status: 400, body: { error: { message: echo } })

    e = begin
      client.ask(step: "llm-index-ideas", messages: messages, max_tokens: 10)
    rescue Quaack::Driver::LLM::Error => e
      e
    end

    expect(without_sizes(e.message)).to eq("llm_bad_request: the API answered 400: saw [key], [key], and [key]")
    expect(error_text(e)).not_to include("SENTINEL")
  end

  it "shows a top-level message, the way Bedrock sends one, scrubbed" do
    fake.error_body("llm-index-ideas", status: 400, body: { message: "bad input for SENTINEL-OWN-KEY", other: "x" })

    expect(without_sizes(gateway_error.message)).to eq("llm_bad_request: the API answered 400: bad input for [key]")
  end

  it "keeps an ordinary API message whole" do
    fake.error("llm-index-ideas", status: 400, message: "prompt is too long: 250000 tokens > 200000 maximum")

    expect(without_sizes(gateway_error.message))
      .to eq("llm_bad_request: the API answered 400: prompt is too long: 250000 tokens > 200000 maximum")
  end

  it "shows the connection error's own message when there's no response" do
    fake.drop("llm-index-ideas")

    expect(without_sizes(gateway_error.message)).to eq("llm_unavailable: fake dropped connection")
  end
end
