# frozen_string_literal: true

require_relative "error"
require_relative "reply_json"

module Quaack
  module Driver
    module LLM
      # Asks an LLM for text or JSON, whichever provider the settings name.
      # It's the front every caller uses, and it knows nothing about any
      # provider's API: `ask` takes a step and a conversation, and the
      # provider's adapter makes the calls.
      #
      #   client = Client.new(burndown: burndown)
      #   client.ask(step: "5a-5", system: "...", messages: [{ role: "user", content: "..." }],
      #              max_tokens: 4000)                          # => "CREATE INDEX ..."
      #   client.ask(step: "6a", ..., schema: { type: "object", ... })   # => { "rewrites" => [...] }
      #
      # The front owns what's the same for every provider: the JSON_ONLY
      # line, parsing and checking JSON replies (ReplyJSON), counting every
      # attempt in the burndown under its step (15b), the error rules (see
      # Error), and the guard below.
      #
      # An adapter is built as `new(settings:, transport:, **options)`, and
      # raises Error for credentials it can't find. It answers
      # `reply(step:, system:, messages:, max_tokens:, schema:, count:)`
      # with the reply's text. It calls `count` once for every attempt it
      # makes, retries included, before the attempt goes out; with a schema
      # it asks for structured output if the provider has it; and it raises
      # Error with one of the rules for every way the call can fail.
      #
      # `transport` is the adapter's edge, which specs fake, such as FakeLLM
      # for Anthropic. Leave it nil to call the real API. While specs run,
      # that raises RealClientInSpecs, unless QUAACK_ALLOW_REAL_LLM is 1, so
      # no spec reaches the network by mistake. Specs are running if RSpec is
      # loaded or QUAACK_SPECS is 1, which the spec helpers set so child
      # processes inherit it.
      class Client
        ALLOW_REAL_ENV = "QUAACK_ALLOW_REAL_LLM"
        SPECS_ENV = "QUAACK_SPECS"

        # Ends every system prompt that asks for a schema. Structured output
        # holds the API to the schema where the provider has it; this helps
        # where it doesn't.
        JSON_ONLY = "Reply with only the JSON object, with no code fences, commentary, or trailing text."

        # The Burndown each call is counted in, for the report (15b).
        attr_reader :burndown

        # settings are LLM.settings, the environment's alone, unless given.
        # model, if given, overrides theirs. The other options go to the
        # adapter, such as api_key: or max_retries: for Anthropic.
        def initialize(burndown:, settings: LLM.settings, model: nil, transport: nil, **)
          refuse_real_client_in_specs unless transport

          settings = settings.with(model:) if model
          @burndown = burndown
          @adapter = LLM.adapter(settings.provider).new(settings:, transport:, **)
        end

        # Asks for one reply and returns its text. With `schema`, a JSON
        # schema, it asks for output that matches it and returns the parsed
        # JSON. With `json: true` and no schema, it parses the text as JSON,
        # for a prompt that asks for JSON itself.
        #
        # Burndown#llm_call refuses a step that isn't one of
        # Protocol::Burndown::LLM_STEPS, and the adapter counts before each
        # attempt goes out, so a bad step raises ArgumentError before any.
        def ask(step:, messages:, max_tokens:, system: nil, schema: nil, json: false) # rubocop:disable Metrics/ParameterLists
          system = [system, JSON_ONLY].compact.join("\n\n") if schema
          count = -> { @burndown.llm_call(step) }
          text = @adapter.reply(step:, system:, messages:, max_tokens:, schema:, count:)
          schema || json ? ReplyJSON.parse(text, schema) : text
        end

        private

        def refuse_real_client_in_specs
          return unless defined?(::RSpec) || ENV[SPECS_ENV] == "1"
          return if ENV[ALLOW_REAL_ENV] == "1"

          raise RealClientInSpecs, "a spec built an LLM client that would call the real API. " \
                                   "Pass a transport, such as FakeLLM, or set #{ALLOW_REAL_ENV}=1 to mean it."
        end
      end
    end
  end
end
