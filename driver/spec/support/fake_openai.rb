# frozen_string_literal: true

require "json"
require "openai"
require "quaack/driver/llm"

# A stand-in for an OpenAI-compatible Chat Completions API, for specs. It's
# FakeLLM's twin for the openai_compatible provider: it plugs in as the
# LLM::Client's transport, which the OpenAICompatibleAdapter hands to the
# openai gem as its HTTP client, so everything above it runs for real: the
# client, the adapter, the gem's request building, retries, and response
# parsing, the burndown count, and JSON parsing. Nothing ever reaches the
# network.
#
# Script it by step, then build a client from it:
#
#   fake = FakeOpenAI.new
#   fake.reply("llm-index-ideas", "CREATE INDEX ...")            # a text answer
#   fake.reply("llm-rewrites", { "rewrites" => [] })            # a Hash or Array goes out as JSON text
#   fake.error("llm-counterexamples", status: 503)                    # one failed attempt, which the gem may retry
#   fake.raw("llm-rewrites", "[1]")                             # a 200 whose body isn't a completion
#   fake.raw("llm-rewrites", "<p>", content_type: "text/html") # ... with another content-type, or nil for none
#   client = fake.client(burndown: burndown)
#
# Each step's answers are used in the order they were scripted, one per
# attempt. An attempt for a step with nothing left scripted raises, so a spec
# can't pass on an answer it didn't expect.
#
# `asks` records every attempt, in order, as an Ask with the step, the
# request body the gem built (parsed, with symbol keys), and the URL it went
# to. Headers aren't recorded, so the API key never is.
class FakeOpenAI
  Ask = Data.define(:step, :body, :url)

  MODEL = "fake-model"
  BASE_URL = "https://llm.example.com/v1"

  # The content-type of every reply, unless a raw one names another.
  JSON_TYPE = "application/json"

  # The finish reason of a reply cut short at the token limit.
  CUT_SHORT = "length"

  class Unscripted < StandardError; end

  attr_reader :asks

  def initialize
    @scripts = Hash.new { |h, k| h[k] = [] }
    @asks = []
  end

  # Queues one successful answer for step. `finish_reason` is the one the
  # API reports, such as "length" for a reply cut short.
  def reply(step, answer, finish_reason: "stop")
    text = answer.is_a?(String) ? answer : JSON.generate(answer)
    @scripts[step] << completion({ role: "assistant", content: text }, finish_reason)
    self
  end

  # Queues one successful answer for step whose message is `message` as it
  # is, such as one with no content.
  def reply_message(step, message, finish_reason: "stop")
    @scripts[step] << completion(message, finish_reason)
    self
  end

  # Queues one reply cut short at the token limit.
  def cut_short(step, text) = reply(step, text, finish_reason: CUT_SHORT)

  # Queues one failed attempt for step, an HTTP error the way OpenAI sends
  # it. `retry_after_ms` keeps the gem's backoff short. `param` is the
  # request parameter the error names, if any, and `message` the body's.
  # `headers` adds response headers.
  def error(step, status:, retry_after_ms: "1", param: nil, message: "fake error #{status}", headers: {}) # rubocop:disable Metrics/ParameterLists
    body = { error: { message: message, type: "invalid_request_error", param: param, code: nil } }
    @scripts[step] << [status, { "content-type" => JSON_TYPE, "retry-after-ms" => retry_after_ms, **headers }, body]
    self
  end

  # Queues one attempt for step that answers status with `body`, a Hash
  # sent as JSON or text sent as it is.
  def error_body(step, status:, body:)
    @scripts[step] << [status, { "content-type" => JSON_TYPE, "retry-after-ms" => "1" }, body]
    self
  end

  # Queues one attempt for step that answers 200 with `body`, text sent as
  # it is, such as a body that isn't a completion. `content_type` is the
  # reply's content-type header, or nil for none at all.
  def raw(step, body, content_type: JSON_TYPE)
    @scripts[step] << [200, { "content-type" => content_type }.compact, body]
    self
  end

  # Queues one attempt for step that fails to connect, the way a dropped
  # network does before the request goes out.
  def drop(step)
    @scripts[step] << :drop
    self
  end

  # The settings of an openai_compatible provider at BASE_URL.
  def self.settings(model: MODEL, **)
    Quaack::Driver::LLM.settings({ "provider" => "openai_compatible", "model" => model, "base_url" => BASE_URL,
                                   ** }, env: {})
  end

  # A real LLM::Client, for the openai_compatible provider, whose every
  # attempt comes here.
  def client(burndown:, model: MODEL, settings: self.class.settings, api_key: "fake-key", **)
    Quaack::Driver::LLM::Client.new(api_key:, model:, settings:, burndown:, transport: self, **)
  end

  # The system prompt an attempt sent: the content of its system message,
  # which comes first, or nil when there's none.
  def system_prompt(ask)
    first = ask.body[:messages].first
    first[:content] if first[:role] == "system"
  end

  # The model an attempt asked for.
  def model(ask) = ask.body[:model]

  # The transport interface the adapter calls, once per attempt: the gem's
  # per-attempt request, and the step it's for. Returns the gem's response.
  def call(request, step:)
    @asks << Ask.new(step: step, body: JSON.parse(request.body, symbolize_names: true), url: request.url.to_s)
    scripted = @scripts[step].shift
    raise Unscripted, "FakeOpenAI has no answer scripted for step #{step}" unless scripted
    if scripted == :drop
      raise OpenAI::Errors::APIConnectionError.new(url: request.url, message: "fake dropped connection",
                                                   request_may_have_been_sent: false)
    end

    status, headers, body = scripted
    OpenAI::HTTPClient::Response.new(status: status, headers: headers,
                                     body: body.is_a?(String) ? body : JSON.generate(body))
  end

  private

  def completion(message, finish_reason)
    body = { id: "chatcmpl-fake", object: "chat.completion", created: 0, model: MODEL,
             choices: [{ index: 0, message: message, finish_reason: finish_reason, logprobs: nil }],
             usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } }
    [200, { "content-type" => JSON_TYPE }, body]
  end
end
