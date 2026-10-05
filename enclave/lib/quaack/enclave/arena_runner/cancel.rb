# frozen_string_literal: true

require_relative "../server_clock"

module Quaack
  module Enclave
    class ArenaRunner
      # Names a cancel (SQLSTATE 57014). statement_timeout and any other
      # cancel, such as a self-cancel or an operator's pg_cancel_backend,
      # share the SQLSTATE, and the message text depends on lc_messages, so
      # time on the arena server's clock tells them apart, as in
      # RunDiscipline (see ServerClock).
      module Cancel
        SAVEPOINT = "SAVEPOINT #{ServerClock::SAVEPOINT};".freeze

        module_function

        # Sets statement_timeout for the transaction, and the savepoint the
        # first mark releases.
        def timeout_sql(timeout_ms) = "SET LOCAL statement_timeout = #{timeout_ms}; #{SAVEPOINT}"

        # ServerClock.mark, for a statement about to run. Each mark sets
        # ServerClock's savepoint, so it first releases the one before it,
        # set by the last mark or with the timeout, whose statement has
        # finished: savepoints left to pile up would each hold a
        # subtransaction until the rollback.
        def mark(connection) = ServerClock.mark(connection, "RELEASE #{SAVEPOINT}")

        # started is ServerClock.mark from just before the statement was
        # sent, or nil for a call with no mark, such as BEGIN or a SET,
        # which can't run for anything like a timeout. The timeout can't
        # fire before timeout_ms has passed since the mark, so a cancel that
        # comes sooner is some other cancel. If the clock can't be read
        # after the cancel, it isn't counted as the timeout either.
        def rule(connection, started, timeout_ms)
          return :statement_canceled unless started

          ServerClock.timed_out?(connection, started, timeout_ms) ? :statement_timeout : :statement_canceled
        rescue StandardError
          :statement_canceled
        end
      end
    end
  end
end
