# frozen_string_literal: true

require "json"
require "quaack/protocol/whitelist"
require "quaack/protocol/burndown"
require_relative "../enclave_error"
require_relative "lexical"

module Quaack
  module Driver
    module Transport
      # Reads what one call to the enclave script printed, by the contract
      # its CLI keeps (see enclave/lib/quaack/enclave/cli.rb and cli/output.rb):
      #
      # - Blank lines and lines that aren't JSON are skipped. A write cut
      #   off by a signal can leave a partial line, and the CLI starts its
      #   next line on a line of its own, so a partial line never swallows
      #   the error line after it. A line that isn't valid UTF-8 counts as
      #   one that isn't JSON, since a cut can split a character.
      # - A run has failed if it printed an error line anywhere, exited
      #   nonzero, died by a signal, or its last non-blank line isn't the
      #   done line. A failed run's other lines are all discarded, since
      #   valid-looking lines can come before its error line.
      #
      # So the first error line decides the EnclaveError, if there is one.
      # Otherwise a run that didn't end cleanly is incomplete.
      #
      # A run that did end cleanly must also have printed only what
      # Protocol::WHITELIST allows: each JSON line an object whose type is on
      # the whitelist, with no field the whitelist doesn't list for it, no
      # key repeated, nested at most MAX_NESTING deep, and only one done
      # line, the last. The enclave's egress function never sends anything
      # else, so anything else means the two sides don't agree on the
      # protocol, as when the enclave's gem is a different version. The
      # driver refuses the whole run then (rule unexpected_output), rather
      # than dropping what it doesn't know and going on with the rest, since
      # a message missing from a run's output can change what the run means.
      # The error names none of the fields or values it refused.
      #
      # It must read a line the same way whichever json is loaded. The
      # laptop may run the driver outside Bundler, with Ruby 3.4's default
      # json (2.9.1), which reads comments, unknown escapes such as \q, and
      # repeated keys that json 3 refuses. JSON.generate never writes any of
      # those, or a number too big for a Float, which both read as Infinity.
      # So a line that starts like a message, with {, and holds a comment or
      # an unknown escape is refused, as is one with a Float that isn't
      # finite, on either version.
      module Reply
        # The error line's fields, checked for the shapes the enclave's
        # ErrorFilter gives them. The driver can't load the enclave, so the
        # patterns are repeated here.
        RULE = /\A[a-z][a-z0-9_]{0,62}\z/
        STEP = /\A[a-z0-9][a-z0-9_-]{0,62}\z/
        SQLSTATE = /\A[0-9A-Z]{5}\z/
        # A volatile_function refusal's function (README 3d), as the
        # enclave's ErrorFilter shapes it: one unquoted qualified name.
        FUNCTION = /\A[a-z_][a-z0-9_$]{0,62}\.[a-z_][a-z0-9_$]{0,62}\z/

        # The deepest a message may nest: the default of the JSON.generate
        # that the enclave's egress function writes each line with, so the
        # driver reads anything egress can send.
        MAX_NESTING = 100

        # The whitelist with String names, as parsed JSON has them.
        FIELDS = Protocol::WHITELIST.to_h { |type, fields| [type.name, fields.map(&:name)] }.freeze

        # A line that is JSON, but not a message the protocol allows.
        REFUSED = Object.new.freeze

        # Parsing into this finds a key repeated in one object: the parser
        # sets each key with []=.
        class UniqueKeys < Hash
          class Repeated < StandardError; end

          def []=(key, value)
            raise Repeated, "a key is repeated" if key?(key)

            super
          end
        end

        module_function

        # The messages stdout holds, as Hashes with String keys, not counting
        # the done line. status is the run's Process::Status. It raises
        # EnclaveError, naming subcommand, if the run failed.
        def parse(stdout, status, subcommand:)
          lines = lines(stdout).filter_map { line(it) }
          messages = lines.grep(Hash)
          error!(subcommand, status, messages)
          raise failure(subcommand, status), cause: nil unless status.success? && done?(lines.last)
          raise failure(subcommand, status, rule: "unexpected_output"), cause: nil unless allowed?(lines)

          messages[0...-1]
        end

        # Raises the first error line's EnclaveError, if there's one.
        def error!(subcommand, status, messages)
          error = messages.find { it["type"] == "error" }
          raise failure(subcommand, status, error), cause: nil if error
        end

        # How the process ended, for an EnclaveError.
        def ending(status)
          { exit_status: status.exitstatus, signal: status.termsig && Signal.signame(status.termsig) }
        end

        # stdout's non-blank lines, each as UTF-8 text, or :skip for one
        # that isn't valid UTF-8.
        def lines(stdout)
          stdout.b.split("\n").filter_map do |line|
            next if line.strip.empty?

            line.force_encoding(Encoding::UTF_8)
            line.valid_encoding? ? line : :skip
          end
        end

        # A line's parsed JSON: a Hash, REFUSED for JSON that isn't one or
        # is too deep or repeats a key, or :skip for a line that isn't JSON.
        # A line that isn't JSON still counts as the last line, so it's
        # returned as :skip rather than dropped.
        def line(line)
          return :skip if line == :skip
          return REFUSED if line.lstrip.start_with?("{") && Lexical.problem?(line)
          return :skip unless json?(line)

          object = strict(line)
          object.instance_of?(Hash) && Lexical.finite?(object) ? object : REFUSED
        end

        # Whether line is JSON at all, whatever keys it repeats. json 3
        # refuses a repeated key unless asked not to, and json 2.9.1, Ruby
        # 3.4's default, ignores the option. A line nested too deep counts
        # as JSON, so it's refused, not skipped, even though the parser
        # stops before it can tell whether the rest is JSON.
        def json?(line)
          JSON.parse(line, max_nesting: MAX_NESTING, allow_duplicate_key: true)
          true
        rescue JSON::NestingError
          true
        rescue JSON::ParserError
          false
        end

        # line parsed, or REFUSED if it's too deep or repeats a key. json 3
        # raises its own ParserError for a repeated key, and json 2.9.1 takes
        # the last one, but it sets each key with []=, which UniqueKeys
        # catches. So the first parse checks keys on either version, and the
        # second gives plain Hashes.
        def strict(line)
          JSON.parse(line, max_nesting: MAX_NESTING, object_class: UniqueKeys)
          JSON.parse(line, max_nesting: MAX_NESTING)
        rescue JSON::ParserError, UniqueKeys::Repeated
          REFUSED
        end

        def done?(line) = line.is_a?(Hash) && line["type"] == "done"

        # Whether every line is a message the whitelist allows, and only the
        # last is the done line.
        def allowed?(lines)
          lines.each_with_index.all? do |line, index|
            next true if line == :skip
            next false unless line.is_a?(Hash) && (done?(line) == (index == lines.size - 1))

            message?(line)
          end
        end

        # Whether line is a message of a type on the whitelist, with only the
        # fields it lists for it. A burndown must also pass
        # Protocol::Burndown.valid?, as egress checks before sending one.
        def message?(line)
          fields = FIELDS[line["type"]]
          return false unless fields && (line.keys - ["type"] - fields).empty?

          line["type"] != "burndown" || Protocol::Burndown.valid?(stages: line["stages"], totals: line["totals"])
        end

        def failure(subcommand, status, error = nil, rule: "incomplete")
          fields = error ? error_fields(error) : { rule: }
          EnclaveError.new(subcommand:, **fields, **ending(status))
        end

        def error_fields(error)
          { rule: shaped(error["rule"], RULE) || "unexpected_output", step: shaped(error["step"], STEP),
            sqlstate: shaped(error["sqlstate"], SQLSTATE), function: shaped(error["function"], FUNCTION) }
        end

        def shaped(value, pattern) = (value if value.instance_of?(String) && value.match?(pattern))
      end
    end
  end
end
