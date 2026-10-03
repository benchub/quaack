# frozen_string_literal: true

module Quaack
  module Driver
    # A call to the enclave script that failed (see Transport). It carries
    # only what the driver can trust to be shape-class data: the subcommand
    # the driver asked for, the step, rule, and SQLSTATE from the enclave's
    # error line (each checked for shape, and nil if it's missing or not
    # shaped), a volatile_function refusal's function and a
    # run_server_other_clients failure's clients (each pid and start time),
    # likewise checked, and how the process ended. It never carries the process's
    # output, and it's raised with no cause.
    #
    # rule is the error line's rule, or one of the driver's own:
    #
    # - incomplete: no error line, and the run didn't end with its done
    #   line, exit 0, and no signal. A step that called exit!, a process
    #   killed by SIGKILL, and an ssh session that couldn't connect all end
    #   up here.
    # - unexpected_output: the run printed a line the driver refuses, such
    #   as a message of a type or with a field not on the protocol's
    #   whitelist, so the two sides disagree on the protocol.
    # - timeout: the run took longer than the transport's timeout, so the
    #   driver killed it.
    # - output_too_large: the run printed more than the transport reads, so
    #   the driver killed it.
    class EnclaveError < StandardError
      # sysexits.h's EX_USAGE and EX_SOFTWARE, as the enclave's CLI uses
      # them: the CLI refused the call, or a step failed.
      EX_USAGE = 64
      EX_SOFTWARE = 70

      attr_reader :subcommand, :rule, :step, :sqlstate, :reason, :function, :clients, :exit_status, :signal

      # exit_status is the process's exit status, or nil if a signal ended
      # it. signal is that signal's name, such as "TERM", or nil.
      def initialize(subcommand:, rule:, step: nil, sqlstate: nil, reason: nil, function: nil, clients: nil, # rubocop:disable Metrics/ParameterLists
                     exit_status: nil, signal: nil)
        @subcommand = subcommand
        @rule = rule
        @step = step
        @sqlstate = sqlstate
        @reason = reason
        @function = function
        @clients = clients
        @exit_status = exit_status
        @signal = signal
        super(describe)
      end

      # The CLI refused the call, as for an unknown subcommand or option.
      def usage? = exit_status == EX_USAGE

      # The step ran and failed.
      def step_failed? = exit_status == EX_SOFTWARE

      # A signal ended the process.
      def killed? = !signal.nil?

      # The rule, and for query_unparsable a fixed note naming pg_query's
      # grammar, which is older than production's Postgres. The enclave's
      # error line holds only the rule, so the driver adds the note.
      def rule_with_note
        return "#{rule}: #{reason_message(reason)}" if %w[query_unreadable plan_unreadable].include?(rule) && reason

        return rule unless rule == "query_unparsable"

        require "pg_query"
        major = PgQuery::PG_VERSION_NUM / 10_000
        "#{rule} (pg_query parses with the Postgres #{major} grammar; " \
          "Postgres #{major + 1}-only syntax isn't supported yet)"
      end

      private

      def describe
        details = (line_details + ending_details).compact
        "quaacks #{subcommand} failed: #{rule}#{" (#{details.join(", ")})" unless details.empty?}"
      end

      # What the error line said beyond its rule.
      def line_details
        [("step #{step}" if step), ("SQLSTATE #{sqlstate}" if sqlstate),
         ("reason #{reason_message(reason)}" if reason),
         ("function #{function}" if function), ("clients #{described_clients}" if clients)]
      end

      def ending_details = [("exit #{exit_status}" if exit_status), ("signal #{signal}" if signal)]

      def described_clients = clients.map { "pid #{it["pid"]} started #{it["backend_start"]}" }.join(", ")

      def reason_message(reason)
        {
          "missing" => "no such file on the jump server",
          "symlink" => "path is a symlink on the jump server",
          "not_regular_file" => "not a regular file on the jump server",
          "permission_denied" => "permission denied on the jump server"
        }.fetch(reason)
      end
    end
  end
end
