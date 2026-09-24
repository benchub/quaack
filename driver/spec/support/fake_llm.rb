# frozen_string_literal: true

require "anthropic"
require "json"
require "quaack/driver/llm"

# A stand-in for the Anthropic API, for specs. It plugs in as the
# LLM::Client's transport, the one edge the client has, so everything above
# it runs for real: the client, the anthropic gem's request building, retries,
# and response parsing, the burndown count, and JSON parsing. Nothing ever
# reaches the network.
#
# Script it by step, then build a client from it:
#
#   fake = FakeLLM.new
#   fake.reply("5a-5", "CREATE INDEX ...")            # a text answer
#   fake.reply("6a", { "rewrites" => [] })            # a Hash or Array goes out as JSON text
#   fake.error("10a", status: 529)                    # one failed attempt, which the gem may retry
#   client = fake.client(burndown: burndown)
#
# Each step's answers are used in the order they were scripted, one per
# attempt. An attempt for a step with nothing left scripted raises, so a spec
# can't pass on an answer it didn't expect.
#
# `asks` records every attempt, in order, as an Ask with the step and the
# request body the gem built: model, max_tokens, system, messages, and
# output_config. Headers aren't recorded, so the API key never is.
class FakeLLM
  Ask = Data.define(:step, :body)

  # The error type the real API sends with each status.
  ERROR_TYPES = {
    400 => "invalid_request_error", 401 => "authentication_error", 403 => "permission_error",
    404 => "not_found_error", 429 => "rate_limit_error", 500 => "api_error", 529 => "overloaded_error"
  }.freeze

  class Unscripted < StandardError; end

  attr_reader :asks

  def initialize
    @scripts = Hash.new { |h, k| h[k] = [] }
    @asks = []
  end

  # Queues one successful answer for step. `stop_reason` is the one the API
  # reports, such as "max_tokens" for a reply cut short.
  def reply(step, answer, stop_reason: "end_turn")
    text = answer.is_a?(String) ? answer : JSON.generate(answer)
    @scripts[step] << message_response([{ type: "text", text: text }], stop_reason)
    self
  end

  # Queues one successful answer for step with these content blocks, such
  # as none at all.
  def reply_blocks(step, blocks, stop_reason: "end_turn")
    @scripts[step] << message_response(blocks, stop_reason)
    self
  end

  # Queues one failed attempt for step, an HTTP error the way the API sends
  # it. `retry_after_ms` keeps the gem's backoff short.
  def error(step, status:, retry_after_ms: "1")
    type = ERROR_TYPES.fetch(status, "api_error")
    body = { type: "error", error: { type: type, message: "fake #{type}" } }
    @scripts[step] << [status, { "retry-after-ms" => retry_after_ms }, body]
    self
  end

  # Queues one attempt for step that fails to connect, the way a dropped
  # network does.
  def drop(step)
    @scripts[step] << :drop
    self
  end

  # A real LLM::Client whose every attempt comes here.
  def client(burndown:, model: Quaack::Driver::LLM::DEFAULT_MODEL, **)
    Quaack::Driver::LLM::Client.new(api_key: "fake-key", model: model, burndown: burndown, transport: self, **)
  end

  # The transport interface LLM::Client calls, once per attempt: the gem's
  # per-attempt request, and the step it's for. Returns the gem's response.
  def call(request, step:)
    @asks << Ask.new(step: step, body: request.body)
    scripted = @scripts[step].shift
    raise Unscripted, "FakeLLM has no answer scripted for step #{step}" unless scripted
    if scripted == :drop
      raise Anthropic::Errors::APIConnectionError.new(url: request.url, message: "fake dropped connection")
    end

    status, headers, body = scripted
    Anthropic::APIResponse.new(status: status, headers: { "content-type" => "application/json", **headers },
                               body: JSON.generate(body), request: request)
  end

  private

  def message_response(blocks, stop_reason)
    body = { id: "msg_fake", type: "message", role: "assistant", model: "fake", content: blocks,
             stop_reason: stop_reason, stop_sequence: nil, usage: { input_tokens: 1, output_tokens: 1 } }
    [200, {}, body]
  end
end
