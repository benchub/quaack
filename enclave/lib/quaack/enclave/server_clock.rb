# frozen_string_literal: true

require "pg"

module Quaack
  module Enclave
    # Tells a statement_timeout from any other cancel by the server's clock.
    #
    #   started = ServerClock.mark(connection, "SET LOCAL statement_timeout = 500;")
    #   ... the statement is cancelled ...
    #   ServerClock.timed_out?(connection, started, 500)
    #
    # Both share SQLSTATE 57014 and the message text depends on lc_messages,
    # so a cancel counts as the timeout only if timeout_ms has passed since
    # the statement started. statement_timeout fires by the server's clock,
    # and the jump server's can run at another rate, so time is read on the
    # server, by clock_timestamp(), never on the enclave.
    #
    # mark runs inside a transaction, before the statement, and sets a
    # savepoint, so after a cancel timed_out? can roll back to it and read
    # the clock again in a transaction that isn't aborted. Neither read is
    # part of the statement, so neither adds to its timing.
    #
    # It uses only the connection's exec. ArenaRunner reads NOW_SQL itself,
    # in each statement's own round trip, rather than set a savepoint per
    # statement, and names READ_ERRORS rather than a PG constant.
    module ServerClock
      SAVEPOINT = "quaack_server_clock"
      NOW_SQL = "SELECT extract(epoch FROM clock_timestamp()) * 1000"
      # What a failed read of the clock raises, as when the connection
      # drops. Anything else, such as a NoMethodError, or Float's
      # ArgumentError when what's read isn't a clock, is a bug in the
      # enclave, and is raised, not taken for a failed read.
      READ_ERRORS = [PG::Error].freeze

      module_function

      # Runs prefix, statements that end in a semicolon, then sets the
      # savepoint, and returns the server's clock in ms, all in one round
      # trip.
      def mark(connection, prefix = "")
        ms(connection, "#{prefix} SAVEPOINT #{SAVEPOINT};")
      end

      # After a cancel: rolls back to mark's savepoint and says whether
      # timeout_ms has passed on the server's clock since started. When it
      # reads the clock, the transaction is usable again afterwards; the
      # caller rolls it back either way. If the clock can't be read,
      # the cancel can't be shown to be the timeout, so it's false, and the
      # caller raises the cancel itself, not the read's error, unless its
      # ROLLBACK fails too, as when the connection has dropped. ArenaRunner
      # does the same, reporting statement_canceled (see ArenaRunner::Cancel).
      def timed_out?(connection, started, timeout_ms)
        ms(connection, "ROLLBACK TO SAVEPOINT #{SAVEPOINT};") - started >= timeout_ms
      rescue *READ_ERRORS
        false
      end

      def ms(connection, prefix)
        Float(connection.exec("#{prefix} #{NOW_SQL}").getvalue(0, 0))
      end
    end
  end
end
