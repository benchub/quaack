# frozen_string_literal: true

require_relative "production_failed_note"

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
    #   killed by SIGKILL, and an ssh session that ended mid-call all end
    #   up here.
    # - ssh_failed: ssh exited 255 with nothing on stdout, and a probe that
    #   runs no quaacks couldn't ssh to the jump server either
    #   (Transport::Ssh).
    # - unexpected_output: the run printed a line the driver refuses, such
    #   as a message of a type or with a field not on the protocol's
    #   whitelist, so the two sides disagree on the protocol.
    # - timeout: the run took longer than the transport's timeout, so the
    #   driver killed it. timeout_seconds is that timeout, and the note
    #   says which setting raises it.
    # - output_too_large: the run printed more than the transport reads, so
    #   the driver killed it.
    class EnclaveError < StandardError
      # sysexits.h's EX_USAGE and EX_SOFTWARE, as the enclave's CLI uses
      # them: the CLI refused the call, or a step failed.
      EX_USAGE = 64
      EX_SOFTWARE = 70

      attr_reader :subcommand, :rule, :exit_status, :signal, :timeout_seconds

      # What run_from_older_version means: the run's store is in an older
      # format, whose entries this version would misread.
      OLDER_VERSION = "an older version of QUAACK started this run, and this version can't resume it. " \
                      "Start a new run with quaack start."

      # What incomplete's note adds for exit 255, and what ssh_failed's says.
      EXIT_255 = "The ssh session failed or ended, or the remote process was killed: check your ssh login, " \
                 "the network, and the jump server's kernel log (for the OOM killer) and sshd log"
      SSH_FAILED = "couldn't ssh to the jump server; check your ssh login or network"

      # Where a connection's other settings come from, for both connection
      # failures' notes.
      LIBPQ_SETUP = "your libpq setup on the jump server: PG* environment variables, ~/.pg_service.conf with " \
                    "PGSERVICE, and ~/.pgpass. A non-interactive ssh session may not load the shell rc file " \
                    "that sets them."
      UNKNOWN_SERVER = "the production server you gave quaack start"
      RUN_SERVER_SETUP = "Its host, port, and databases are the ones run-server was given: the --host, --port, " \
                         "--racetrack-db, and --arena-db you gave quaack setup or quaack run, and your " \
                         "run_server_command's for any you didn't. The user and password come from " \
                         "#{LIBPQ_SETUP}".freeze

      # The error line's fields beyond its rule.
      LINE_FIELDS = %i[step sqlstate reason function column clients cycle].freeze
      LINE_FIELDS.each { |field| define_method(field) { @line[field] } }

      # What a failed command prints after its name: an EnclaveError's
      # rule_with_note, with next_step and where (jump:, server: and port:),
      # or any other error's message.
      def self.shown(error, next_step, **where)
        error.is_a?(self) ? error.rule_with_note(next_step:, **where) : error.message
      end

      # exit_status is the process's exit status, or nil if a signal ended
      # it. signal is that signal's name, such as "TERM", or nil.
      def initialize(subcommand:, rule:, step: nil, sqlstate: nil, reason: nil, function: nil, column: nil, # rubocop:disable Metrics/ParameterLists
                     clients: nil, cycle: nil, exit_status: nil, signal: nil, timeout_seconds: nil)
        @subcommand = subcommand
        @timeout_seconds = timeout_seconds
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
      #
      # incomplete gets the subcommand and how it ended, and ssh_failed what
      # to check, then next_step, the caller's words for what to do after,
      # such as the command that resumes the run, or starting a new one when
      # teardown deleted the run's store. Both are the driver's own facts,
      # not the enclave's.
      #
      # production_connection_failed and run_server_connection_failed get
      # where the connection's settings come from, how to test it from jump,
      # the jump host, and what to do next. production's names server and
      # port, the production server and port the operator gave quaack
      # start, when the caller knows them. All come from the laptop's own
      # record of the run, never
      # from the enclave, whose error line holds only the rule: libpq's
      # message can name the user or the database.
      def rule_with_note(next_step: "resume the run", jump: nil, server: nil, port: nil)
        return "#{rule}: #{to_go_on(next_step, jump || "<jump server>", server, port)}" if to_go_on?
        return "#{rule}: #{note}" if note

        return rule unless rule == "query_unparsable"

        require "pg_query"
        major = PgQuery::PG_VERSION_NUM / 10_000
        "#{rule} (pg_query parses with the Postgres #{major} grammar; " \
          "Postgres #{major + 1}-only syntax isn't supported yet)"
      end

      # The rules whose note ends with what to do next.
      def to_go_on? = %w[ssh_failed incomplete production_connection_failed run_server_connection_failed].include?(rule)

      private

      def to_go_on(next_step, jump, server, port)
        case rule
        when "ssh_failed" then "#{SSH_FAILED}, then #{next_step}"
        when "incomplete" then "#{ended}. To go on, #{next_step}"
        when "production_connection_failed" then ProductionFailedNote.call(jump, server, port, next_step)
        else run_server_failed(jump, next_step)
        end
      end

      def run_server_failed(jump, next_step)
        "couldn't connect to the run server. #{RUN_SERVER_SETUP} Test it with `ssh #{jump} 'psql -h <host> " \
          "-p <port> -d <racetrack db> -c \"select 1\"'`. Then #{next_step}"
      end

      # What rule_with_note adds after the rule, or nil.
      def note
        return OLDER_VERSION if rule == "run_from_older_version"
        return timed_out if rule == "timeout" && timeout_seconds
        return reason_message(reason) if %w[query_unreadable plan_unreadable].include?(rule) && reason

        named_schema
      end

      def timed_out
        total = timeout_seconds.ceil
        format("the enclave call timed out after %<h>dh%<m>02dm%<s>02ds; raise `enclave_timeout_seconds` in " \
               "~/.quaack/driver.json, or pass --enclave-timeout-seconds to quaack run",
               h: total / 3600, m: total % 3600 / 60, s: total % 60)
      end

      # Which call died, and how. ssh exits 255 for its own failures, and
      # for a remote process that a signal ended.
      def ended
        how = ending_details.compact.first
        return "quaacks #{subcommand} didn't finish" unless how

        "quaacks #{subcommand} ended with #{how}#{". #{EXIT_255}" if exit_status == 255}"
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
