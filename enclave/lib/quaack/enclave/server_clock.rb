# frozen_string_literal: true

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
    # It uses only the connection's exec and names no PG constant, as
    # ArenaRunner needs.
    module ServerClock
      SAVEPOINT = "quaack_server_clock"

      module_function

      # Runs prefix, statements that end in a semicolon, then sets the
      # savepoint, and returns the server's clock in ms, all in one round
      # trip.
      def mark(connection, prefix = "")
        ms(connection, "#{prefix} SAVEPOINT #{SAVEPOINT};")
      end

      # After a cancel: rolls back to mark's savepoint and says whether
      # timeout_ms has passed on the server's clock since started. The
      # transaction is usable again afterwards.
      def timed_out?(connection, started, timeout_ms)
        ms(connection, "ROLLBACK TO SAVEPOINT #{SAVEPOINT};") - started >= timeout_ms
      end

      def ms(connection, prefix)
        Float(connection.exec("#{prefix} SELECT extract(epoch FROM clock_timestamp()) * 1000").getvalue(0, 0))
      end
    end
  end
end
