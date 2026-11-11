# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "copilot_cli_adapter"
require_relative "error"
require_relative "usage"

module Quaack
  module Driver
    module LLM
      # A local Claude Code `claude` command, behind Client. Each ask writes
      # the system prompt and the rest of the provider-neutral prompt to
      # private files, runs the configured argv template without a shell
      # with the prompt file on stdin, and reads the reply from the JSON
      # result print mode writes to stdout. It runs the command the way
      # CopilotCLIAdapter does: its own process group, a timeout, and a
      # stderr tail with tokens hidden.
      class ClaudeCLIAdapter < CopilotCLIAdapter
        SYSTEM_FILE = "system.md"
        SYSTEM_PLACEHOLDER = "{system_file}"
        # Claude Code's own system prompt is for coding. Every ask replaces
        # it, so a step with no system prompt gets this one.
        DEFAULT_SYSTEM = "Follow the user's prompt. Reply only with the answer."
        # An Anthropic API key or OAuth token, and whatever follows
        # "Bearer". A failure's stderr tail shows each as [token].
        TOKEN = /\bsk-ant-[\w-]+|\bBearer\b[ \t]*+[:=]?+[ \t]*+["']?\K[^\s"']+/i
        LOGIN = %r{(?:invalid api key|please run /login|not logged in|oauth token has expired|authentication)}i
        SUBTYPE = /\A[a-z_]{1,64}\z/

        # Print mode with one JSON result, no built-in tools, no MCP servers
        # but the (absent) --mcp-config ones, no skills or slash commands,
        # and no session saved to disk. The system prompt file replaces
        # Claude Code's own.
        DEFAULT_TEMPLATE = [
          "claude", "-p", "--output-format", "json",
          "--model", "{model}",
          "--tools", "",
          "--strict-mcp-config",
          "--disable-slash-commands",
          "--no-session-persistence",
          "--system-prompt-file", SYSTEM_PLACEHOLDER
        ].freeze

        def initialize(settings:, **)
          super
          @template = settings.command_template || DEFAULT_TEMPLATE
          @usage = nil
        end

        # The last reply's tokens, from the result's usage (Client).
        attr_reader :usage

        def reply(step:, system:, messages:, max_tokens:, schema:, count:) # rubocop:disable Metrics/ParameterLists
          count.call
          @usage = nil
          Dir.mktmpdir("quaack-claude-cli") do |dir|
            prompt_file = File.join(dir, PROMPT_FILE)
            system_file = File.join(dir, SYSTEM_FILE)
            write_prompt(prompt_file, prompt_text(step, nil, messages, schema, max_tokens))
            write_prompt(system_file, system || DEFAULT_SYSTEM)
            argv = template(prompt_file, dir).map { it.gsub(SYSTEM_PLACEHOLDER, system_file) }
            run(argv, dir)
          end
        end

        private

        def label = "claude_cli"

        def spawn_env = {}

        def token_pattern = TOKEN

        def run(argv, dir)
          result = spawn_and_capture(argv, dir, File.join(dir, PROMPT_FILE))
          # A command that didn't run, or ran too long, has no result to read.
          raise result.error if result.error && !result.status&.exitstatus

          parsed = parse(result.stdout)
          return text_of(parsed) if parsed
          raise result.error if result.error

          raise not_a_result
        end

        def not_a_result = Error.new("llm_bad_response", "the #{label} command's output isn't its JSON result")

        # stdout's JSON result as a Hash, or nil if it isn't one.
        def parse(stdout)
          parsed = JSON.parse(stdout.force_encoding(Encoding::UTF_8).scrub)
          parsed if parsed.is_a?(Hash) && parsed["type"] == "result"
        rescue JSON::ParserError
          nil
        end

        def text_of(parsed)
          raise result_error(parsed) if parsed["is_error"]

          text = parsed["result"]
          unless text.is_a?(String) && !text.empty?
            raise Error.new("llm_bad_response", "the #{label} command printed no reply")
          end

          @usage = Usage.anthropic(UsageCounts.new(**counts(parsed["usage"])))
          text
        end

        UsageCounts = Data.define(:input_tokens, :output_tokens, :cache_read_input_tokens,
                                  :cache_creation_input_tokens)

        def counts(usage)
          usage = {} unless usage.is_a?(Hash)
          UsageCounts.members.to_h { [it, usage[it.to_s]] }
        end

        # The result's error, naming only its subtype, since its text may
        # quote the prompt or a key.
        def result_error(parsed)
          if parsed["result"].is_a?(String) && parsed["result"].match?(LOGIN)
            return Error.new("llm_auth", "the #{label} command says it isn't logged in")
          end

          subtype = parsed["subtype"]
          detail = subtype.is_a?(String) && subtype.match?(SUBTYPE) ? " (#{subtype})" : ""
          Error.new("llm_unavailable", "the #{label} command reported an error#{detail}")
        end
      end
    end
  end
end
