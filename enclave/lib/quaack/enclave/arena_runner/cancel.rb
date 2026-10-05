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
        module_function

        # started is the server's clock, in ms, read in the statement's own
        # pipeline just before it (see Pipeline), or nil for a call with no
        # reading, such as BEGIN or a SET, which can't run for anything like
        # a timeout. The timeout can't fire before timeout_ms has passed
        # since then, so a cancel that comes sooner is some other cancel.
        #
        # The transaction is aborted, and the runner rolls it back after any
        # error anyway, so this rolls it back now and reads the clock in a
        # transaction of its own, with statement_timeout off, so a nonzero
        # session setting, from the server, the database, the role, or a SET,
        # can't cancel the read. It's a separate query, since the server arms
        # a query's timeout with the setting as the query starts. It then
        # rolls that transaction back too, leaving the connection idle and the
        # session's setting as it was. If the clock can't be read, the cancel
        # isn't counted as the timeout, as in RunDiscipline (see
        # ServerClock.timed_out?).
        #
        # The first ROLLBACK can't turn the timeout off first, since an
        # aborted transaction refuses everything else. Postgres drops the
        # runner's timeout as the transaction aborts, since it was set for the
        # transaction, so that ROLLBACK runs under the session's setting. A
        # nonzero one cancels it if the server is slower than that to reach
        # it, and the cancel reads as statement_canceled (see DESIGN.md).
        def rule(connection, started, timeout_ms)
          return :statement_canceled unless started

          connection.exec("ROLLBACK; BEGIN; #{Pipeline::DISARM_SQL}")
          begin
            now = ServerClock.ms(connection, "")
          ensure
            connection.exec("ROLLBACK")
          end
          now - started >= timeout_ms ? :statement_timeout : :statement_canceled
        rescue StandardError
          :statement_canceled
        end
      end
    end
  end
end
