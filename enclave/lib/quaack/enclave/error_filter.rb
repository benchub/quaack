# frozen_string_literal: true

require_relative "egress"

module Quaack
  module Enclave
    # Error filtering (README, "Where QUAACK runs"): every error the enclave
    # script reports goes out through the egress function as one error line,
    # with only which step failed, which rule it broke, and the Postgres
    # SQLSTATE if there was one.
    #
    #   ErrorFilter.to_egress(unique_violation, step: "9b")
    #   # => '{"type":"error","step":"9b","rule":"internal_error","sqlstate":"23505"}'
    #
    # It never reads an error's message, backtrace, class name, or cause,
    # since any of them can hold a real value, such as the key in a unique
    # violation's DETAIL. What it does read, it checks for shape:
    #
    # - The rule comes from the error's own rule method, if it has one that
    #   gives a lowercase identifier (a String or Symbol) of up to 63
    #   characters. Otherwise it's internal_error.
    # - The SQLSTATE comes from the error's sqlstate method, or from a
    #   PG::Error's result, and must be exactly five digits or capital
    #   letters. Otherwise it's left out. It duck types the result, so this
    #   file doesn't need the pg gem.
    # - The step comes from the caller, and must be a lowercase name of up to
    #   63 characters, such as 3f, 5a-1, or intake. Otherwise it's left out.
    #   Step names start with a digit and hold hyphens, so they get their own
    #   pattern rather than the rule's.
    # - The function comes from the error's function method, and is sent
    #   only when the rule is volatile_function (README 3d). It must be one
    #   plain, unquoted, schema-qualified name, such as pg_catalog.random.
    #   Otherwise it's left out, so a quoted name is never sent.
    #
    # The enclave script runs its work inside guard, with stderr silenced by
    # silence_stderr!, and drops the notices on every database connection
    # with drop_notices. Stderr goes back over ssh to the laptop, so it's a
    # way around the egress function unless it's silenced.
    module ErrorFilter
      RULE = /\A[a-z][a-z0-9_]{0,62}\z/
      STEP = /\A[a-z0-9][a-z0-9_-]{0,62}\z/
      SQLSTATE = /\A[0-9A-Z]{5}\z/
      FUNCTION = /\A[a-z_][a-z0-9_$]{0,62}\.[a-z_][a-z0-9_$]{0,62}\z/
      FUNCTION_RULE = "volatile_function"
      INTERNAL_ERROR = "internal_error"
      # libpq's PG_DIAG_SQLSTATE, the error field code for the SQLSTATE.
      PG_DIAG_SQLSTATE = "C".ord
      # What to_egress sends if the egress function ever fails. It's the line
      # the egress function sends for this message, which a spec checks.
      FALLBACK = '{"type":"error","rule":"internal_error"}'
      # sysexits.h's EX_SOFTWARE, an internal software error.
      EX_SOFTWARE = 70

      module_function

      # The one error line for exception, as a String with no newline. It
      # never raises: anything that goes wrong gives FALLBACK.
      def to_egress(exception, step:)
        rule = name(ask(exception, :rule), RULE) || INTERNAL_ERROR
        message = { type: :error, step: name(step, STEP), rule:, sqlstate: sqlstate(exception),
                    function: (shaped_or_nil(ask(exception, :function), FUNCTION) if rule == FUNCTION_RULE) }
        line = Egress.serialize(message.compact)
        line.is_a?(String) ? line : FALLBACK
      rescue Exception # rubocop:disable Lint/RescueException
        FALLBACK
      end

      # Runs the block and returns its value. If it raises anything, even a
      # stack overflow, a LoadError, or an Interrupt, it writes the one
      # filtered error line to out and returns EX_SOFTWARE, except for a
      # signal, below. Nothing goes to stderr.
      #
      # It lets SystemExit pass, since exit is how a step chooses its own
      # status. A SignalException, such as an Interrupt or the SIGTERM or
      # SIGHUP from a dropped ssh session, gets its error line, so the driver
      # hears the step failed, and is then raised again. Ruby then ends the
      # process with that signal, as the sender meant, rather than letting a
      # caller's loop carry on to the next step. With stderr silenced, Ruby
      # prints nothing for it.
      def guard(step:, out: $stdout)
        yield
      rescue SystemExit
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        write(out, to_egress(e, step:))
        raise if e.is_a?(SignalException)

        EX_SOFTWARE
      end

      # Points $stderr and the process's real stderr, file descriptor 2, at
      # the null device for the rest of the process. That catches warn, Ruby
      # warnings, a dying thread's report, an uncaught exception's backtrace,
      # and anything C code such as libpq writes there. It isn't undone, so
      # at_exit hooks and Ruby's own last words are silenced too.
      def silence_stderr!
        # STDERR, not $stderr: it's the one that owns file descriptor 2.
        STDERR.reopen(File::NULL, "w") # rubocop:disable Style/GlobalStdStream
        $stderr = STDERR
      end

      # Gives connection, such as a PG::Connection, a notice receiver that
      # drops every NOTICE and WARNING, since a RAISE NOTICE can print a row
      # value. Returns the connection.
      #
      # The pg gem (1.6.3) forgets the receiver when the connection is reset,
      # so call this again after every conn.reset, or a later notice goes to
      # stderr. A spec pins that. It also has to be called on each new
      # connection: it can't reach connections it isn't given.
      def drop_notices(connection)
        connection.set_notice_receiver { |_result| nil }
        connection
      end

      # value as a String if it's a String or Symbol matching pattern, and nil
      # otherwise. The class must be exactly String, since a subclass can
      # write itself out as something else.
      def name(value, pattern)
        value = value.name if value.instance_of?(Symbol)
        value if shaped?(value, pattern)
      end

      # ascii_only? first, since matching raises for invalid bytes or an
      # encoding such as UTF-16 that isn't ASCII compatible.
      def shaped?(value, pattern) = value.instance_of?(String) && value.ascii_only? && value.match?(pattern)

      def shaped_or_nil(value, pattern) = (value if shaped?(value, pattern))

      def sqlstate(exception)
        code = ask(exception, :sqlstate)
        code ||= ask(ask(exception, :result), :error_field, PG_DIAG_SQLSTATE)
        code if shaped?(code, SQLSTATE)
      end

      # Calls object's method if it has one, and gives nil if it doesn't or
      # if the method raises.
      def ask(object, method, *)
        object.public_send(method, *) if object.respond_to?(method)
      rescue Exception # rubocop:disable Lint/RescueException
        nil
      end

      # A failed write, such as to a closed pipe, leaves nothing to report
      # to, so it's dropped.
      def write(out, line)
        out.write("#{line}\n")
        out.flush
      rescue Exception # rubocop:disable Lint/RescueException
        nil
      end
    end
  end
end
