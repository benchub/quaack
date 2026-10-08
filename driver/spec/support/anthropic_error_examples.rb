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

  # The LLM::Error an ask raises through a client built with options.
  def error_from(**)
    fake.client(burndown:, max_retries: 0, **).ask(step: "llm-index-ideas", messages:, max_tokens: 10)
    raise "expected an LLM::Error, but the ask succeeded"
  rescue Quaack::Driver::LLM::Error => e
    e
  end

  def echo(message) = fake.error_body("llm-index-ideas", status: 400, body: { error: { message: } })

  # Task 20261007-57: a key too short to be a real one is scrubbed only as
  # a whole token, a run of the characters keys are made of, so it can't
  # cut words apart; next to punctuation, quotes, or slashes it still goes.
  it "scrubs a short own key only where it stands as a whole token" do
    echo("the answer for s was s, (s), \"s\", 's', /s/, key=s; s.")

    expect(without_sizes(error_from(api_key: "s").message))
      .to eq("llm_bad_request: the API answered 400: the answer for [key] was [key], ([key]), \"[key]\", " \
             "'[key]', /[key]/, key=[key]; [key].")
  end

  it "scrubs a key of real length even inside a longer token" do
    key = "SENTINELKEY0123456789"
    echo("saw x#{key}y, #{key}-suffix, and prefix_#{key}")

    e = error_from(api_key: key)

    expect(without_sizes(e.message)).to eq("llm_bad_request: the API answered 400: saw x[key]y, [key]-suffix, " \
                                           "and prefix_[key]")
    expect(error_text(e)).not_to include("SENTINEL")
  end

  it "scrubs a short base_url query value only as a whole token, and a long one anywhere" do
    gateway = "https://gateway.example.test/anthropic?provider=anthropic&key=SENTINELQUERYKEY0123456789"
    echo("anthropic-version too old at anthropicgateway for provider anthropic, keyed xSENTINELQUERYKEY0123456789")

    e = error_from(settings: fake.class.settings("base_url" => gateway))

    expect(without_sizes(e.message))
      .to eq("llm_bad_request: the API answered 400: anthropic-version too old at anthropicgateway for provider " \
             "[key], keyed x[key]")
    expect(error_text(e)).not_to include("SENTINEL")
  end

  it "scrubs base_url's user, its password as written and decoded, and a long path segment" do
    gateway = "https://SENTINEL-USER:SENTINEL-PASS%21@gateway.example.test/SENTINELPATHKEY0123456789/anthropic"
    echo("user SENTINEL-USER, pass SENTINEL-PASS%21 or SENTINEL-PASS!, path /SENTINELPATHKEY0123456789/anthropic")

    e = error_from(settings: fake.class.settings("base_url" => gateway))

    expect(without_sizes(e.message))
      .to eq("llm_bad_request: the API answered 400: user [key], pass [key] or [key], path /[key]/anthropic")
    expect(error_text(e)).not_to include("SENTINEL")
  end

  # Task 20261007-61: a percent sequence that decodes to invalid UTF-8
  # doesn't break the scrub, and what decodes cleanly still goes.
  it "scrubs a base_url value whose percent sequence isn't valid UTF-8, as written and decoded" do
    gateway = "https://gateway.example.test/SENTINELPATHKEY0123%E2/anthropic?key=SENTINEL-QUERY%E2"
    echo("path SENTINELPATHKEY0123%E2 or SENTINELPATHKEY0123\uFFFD, query SENTINEL-QUERY%E2 or " \
         "SENTINEL-QUERY\uFFFD, bare SENTINELPATHKEY0123 and SENTINEL-QUERY")

    e = error_from(settings: fake.class.settings("base_url" => gateway))

    expect(e.cause).to be_nil
    expect(without_sizes(e.message))
      .to eq("llm_bad_request: the API answered 400: path [key] or [key], query [key] or [key], " \
             "bare [key] and [key]")
    expect(error_text(e)).not_to include("SENTINEL")
  end

  # Task 20261007-61: a key's URL-encoded echo goes too, in either case of
  # hex, and with only some of its characters encoded.
  it "scrubs an own key's URL-encoded form" do
    key = "SENTINEL+KEY/0123456789=="
    echo("saw SENTINEL%2BKEY%2F0123456789%3D%3D, SENTINEL%2bKEY%2f0123456789%3d%3d, and SENTINEL+KEY%2F0123456789==")

    e = error_from(api_key: key)

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
