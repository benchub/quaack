# frozen_string_literal: true

module Quaack
  module Enclave
    class ArenaRunner
      # Names a cancel (SQLSTATE 57014) by when it came. statement_timeout
      # and any other cancel, such as a self-cancel or an operator's
      # pg_cancel_backend, share the SQLSTATE, and the message text depends
      # on lc_messages, so time tells them apart, as in RunDiscipline.
      module Cancel
        module_function

        def now_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)

        # started is now_ms from just before the statement was sent. The
        # timeout can't fire before timeout_ms has passed since then, so a
        # cancel that comes sooner is some other cancel.
        def rule(started, timeout_ms)
          now_ms - started >= timeout_ms ? :statement_timeout : :statement_canceled
        end
      end
    end
  end
end
