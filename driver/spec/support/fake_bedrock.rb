# frozen_string_literal: true

require "json"
require "uri"
require_relative "fake_llm"

# A stand-in for Anthropic models on AWS Bedrock, for specs. It's FakeLLM,
# scripted the same way, for the bedrock provider: it plugs in as the
# LLM::Client's transport, which the BedrockAdapter puts past the anthropic
# gem's Bedrock step, so it gets each attempt as it would go out: rewritten
# to Bedrock's invoke URL and signed. Everything above it runs for real,
# including SigV4 signing with fake keys. Nothing ever reaches AWS.
#
# `asks` records each attempt as FakeLLM's does, with the body parsed (symbol
# keys). Bedrock takes the model in the URL, not the body, so `model(ask)`
# reads it from there. `auths` records each attempt's authorization header,
# which with SigV4 holds the access key ID and a signature, never the secret
# key. `session_tokens` records each attempt's x-amz-security-token header,
# which carries temporary credentials' session token (fake ones, in specs).
class FakeBedrock < FakeLLM
  MODEL = "us.anthropic.claude-opus-5-5"
  REGION = "us-west-2"
  ACCESS_KEY = "AKIAQUAACKSPECFAKE01"
  SECRET_KEY = "quaack-spec-fake-secret-key"

  attr_reader :auths, :session_tokens

  def initialize
    super
    @auths = []
    @session_tokens = []
  end

  # The settings of the bedrock provider in REGION, with block's keys too.
  def self.settings(block = {})
    Quaack::Driver::LLM.settings({ "provider" => "bedrock", "model" => MODEL, "aws_region" => REGION, **block },
                                 env: {})
  end

  # A real LLM::Client, for the bedrock provider, signing with the fake keys,
  # whose every attempt comes here. api_key is the secret key, so the shared
  # examples can plant a sentinel in it.
  def client(burndown:, model: MODEL, settings: self.class.settings, api_key: SECRET_KEY, **)
    Quaack::Driver::LLM::Client.new(settings:, model:, burndown:, transport: self, aws_access_key: ACCESS_KEY,
                                    aws_secret_key: api_key, **)
  end

  # Queues one failed attempt for step, an HTTP error the way Bedrock sends
  # it: the exception's name in a header, and a message. `headers` adds
  # response headers.
  def error(step, status:, retry_after_ms: "1", message: "fake error #{status}", headers: {})
    @scripts[step] << [status, { "retry-after-ms" => retry_after_ms, "x-amzn-errortype" => "FakeException", **headers },
                       { message: message }]
    self
  end

  # The model an attempt asked for, from its invoke URL.
  def model(ask) = URI.decode_www_form_component(ask.url[%r{/model/([^/]+)/invoke\z}, 1])

  # A signed request's body is the bytes that were signed. A request with a
  # Bedrock API key isn't signed, so its body is still the gem's Hash.
  def call(request, step:)
    @auths << request.headers["authorization"]
    @session_tokens << request.headers["x-amz-security-token"]
    body = request.body
    text = body.respond_to?(:read) ? body.read.tap { body.rewind } : JSON.generate(body)
    super(request.with(body: JSON.parse(text, symbolize_names: true)), step:)
  end
end
