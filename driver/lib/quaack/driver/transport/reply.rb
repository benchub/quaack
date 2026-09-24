# frozen_string_literal: true

require "json"
require_relative "../enclave_error"

module Quaack
  module Driver
    module Transport
      # Reads what one call to the enclave script printed, by the contract
      # its CLI keeps (see enclave/lib/quaack/enclave/cli.rb and cli/output.rb):
      #
      # - Blank lines and lines that aren't JSON are skipped. A write cut
      #   off by a signal can leave a partial line, and the CLI starts its
      #   next line on a line of its own, so a partial line never swallows
      #   the error line after it.
      # - A run has failed if it printed an error line anywhere, exited
      #   nonzero, died by a signal, or its last non-blank line isn't the
      #   done line. A failed run's other lines are all discarded, since
      #   valid-looking lines can come before its error line.
      #
      # So the first error line decides the EnclaveError, if there is one.
      # Otherwise a run that didn't end cleanly is incomplete.
      module Reply
        # The error line's fields, checked for the shapes the enclave's
        # ErrorFilter gives them. The driver can't load the enclave, so the
        # patterns are repeated here.
        RULE = /\A[a-z][a-z0-9_]{0,62}\z/
        STEP = /\A[a-z0-9][a-z0-9_-]{0,62}\z/
        SQLSTATE = /\A[0-9A-Z]{5}\z/

        DONE = { "type" => "done" }.freeze

        module_function

        # The messages stdout holds, as Hashes with String keys, not counting
        # the done line. status is the run's Process::Status. It raises
        # EnclaveError, naming subcommand, if the run failed.
        def parse(stdout, status, subcommand:)
          messages = lines(stdout).filter_map { message(it) }
          error = messages.find { it["type"] == "error" }
          raise failure(subcommand, status, error) if error
          raise failure(subcommand, status) unless messages.last == DONE && status.success?

          messages[0...-1]
        end

        def lines(stdout) = stdout.split("\n").reject { it.strip.empty? }

        def message(line)
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end

        def failure(subcommand, status, error = nil)
          fields = error ? error_fields(error) : { rule: "incomplete" }
          EnclaveError.new(subcommand:, **fields, exit_status: status.exitstatus,
                                                  signal: status.termsig && Signal.signame(status.termsig))
        end

        def error_fields(error)
          { rule: shaped(error["rule"], RULE) || "unexpected_output", step: shaped(error["step"], STEP),
            sqlstate: shaped(error["sqlstate"], SQLSTATE) }
        end

        def shaped(value, pattern) = (value if value.instance_of?(String) && value.match?(pattern))
      end
    end
  end
end
