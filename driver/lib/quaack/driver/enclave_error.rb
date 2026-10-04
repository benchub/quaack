# frozen_string_literal: true

module Quaack
  module Driver
    # A call to the enclave script that failed (see Transport). It carries
    # only what the driver can trust to be shape-class data: the subcommand
    # the driver asked for, the step, rule, and SQLSTATE from the enclave's
    # error line (each checked for shape, and nil if it's missing or not
    # shaped), a volatile_function refusal's function, a rewrite-test refusal's
    # column (its table, name, and type), an fk_cycle refusal's cycle (its
    # tables, in the order their foreign keys point), and a
    # run_server_other_clients failure's clients (each pid and start time),
    # likewise checked, and how the process ended. It never carries the
    # process's output, and it's raised with no cause.
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

      attr_reader :subcommand, :rule, :exit_status, :signal

      # What run_from_older_version means: the run's store is in an older
      # format, whose entries this version would misread.
      OLDER_VERSION = "an older version of QUAACK started this run, and this version can't resume it. " \
                      "Start a new run with quaack start."

      # The error line's fields beyond its rule.
      LINE_FIELDS = %i[step sqlstate reason function column clients cycle].freeze
      LINE_FIELDS.each { |field| define_method(field) { @line[field] } }

      # exit_status is the process's exit status, or nil if a signal ended
      # it. signal is that signal's name, such as "TERM", or nil.
      def initialize(subcommand:, rule:, step: nil, sqlstate: nil, reason: nil, function: nil, column: nil, # rubocop:disable Metrics/ParameterLists
                     clients: nil, cycle: nil, exit_status: nil, signal: nil)
        @subcommand = subcommand
        @rule = rule
        @line = { step:, sqlstate:, reason:, function:, column:, clients:, cycle: }.freeze
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
      # error line holds only the rule, so the driver adds the note. A
      # rewrite-test refusal that names its column gets the table, column, and type,
      # and an fk_cycle refusal that names its tables gets them. A run an
      # older version started gets what to do instead.
      def rule_with_note
        return "#{rule}: #{note}" if note

        return rule unless rule == "query_unparsable"

        require "pg_query"
        major = PgQuery::PG_VERSION_NUM / 10_000
        "#{rule} (pg_query parses with the Postgres #{major} grammar; " \
          "Postgres #{major + 1}-only syntax isn't supported yet)"
      end

      private

      # What rule_with_note adds after the rule, or nil.
      def note
        return OLDER_VERSION if rule == "run_from_older_version"
        return reason_message(reason) if %w[query_unreadable plan_unreadable].include?(rule) && reason

        named_schema
      end

      def describe
        details = (line_details + named_details + ending_details).compact
        "quaacks #{subcommand} failed: #{rule}#{" (#{details.join(", ")})" unless details.empty?}"
      end

      # What the error line said beyond its rule.
      def line_details
        [("step #{step}" if step), ("SQLSTATE #{sqlstate}" if sqlstate),
         ("reason #{reason_message(reason)}" if reason), ("function #{function}" if function)]
      end

      # The schema and clients the error line named.
      def named_details
        [("column #{described_column}" if column), ("clients #{described_clients}" if clients),
         ("cycle #{described_cycle}" if cycle)]
      end

      def ending_details = [("exit #{exit_status}" if exit_status), ("signal #{signal}" if signal)]

      # The column or cycle a rewrite-test refusal named, or nil.
      def named_schema = (described_column if column) || (described_cycle if cycle)

      def described_column = "#{column["table"]}.#{column["column"]} (#{column["type"]})"

      # An fk_cycle's tables, in the order their foreign keys point.
      def described_cycle = cycle.join(" -> ")

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
