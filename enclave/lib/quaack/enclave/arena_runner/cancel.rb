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
        # error anyway, so this rolls it back now and reads the clock on the
        # idle connection. If the clock can't be read, the cancel isn't
        # counted as the timeout.
        def rule(connection, started, timeout_ms)
          return :statement_canceled unless started

          ServerClock.ms(connection, "ROLLBACK;") - started >= timeout_ms ? :statement_timeout : :statement_canceled
        rescue StandardError
          :statement_canceled
        end
      end
    end
  end
end
