# frozen_string_literal: true

require "pg"
require_relative "../server_clock"

module Quaack
  module Enclave
    class ArenaRunner
      # Sends statements through one libpq pipeline, under one Sync, so they
      # take one round trip, and returns each one's result unchecked. A
      # statement after one that fails comes back aborted.
      #
      # The arena server starts a fresh statement_timeout at each statement
      # in a pipeline, after the one before it has finished, so a clock read
      # sent first is taken before the next statement's timeout starts.
      #
      # The server arms that timeout when a statement starts, with the
      # setting as it is then, so clocked arms it only for its statement:
      # the clock read sets it, and a reset after the statement turns it off
      # again. The clock read, and anything the runner sends between
      # statements, such as its ROLLBACK, then run without the runner's
      # timeout, so a loaded server can't cancel them with it. An error
      # aborts the transaction, and that undoes the setting too, back to the
      # session's, so a ROLLBACK after an abort runs under that (see
      # DESIGN.md).
      module Pipeline
        class Broken < StandardError; end

        module_function

        ARM_SQL = "#{ServerClock::NOW_SQL}, set_config('statement_timeout', $1, true)".freeze
        DISARM_SQL = "SET LOCAL statement_timeout = 0"

        # The server's clock, in ms, read just before sql, in sql's round
        # trip, and the result to check: sql's, or the clock read's if that
        # failed, with no clock then. sql runs with statement_timeout set to
        # timeout_ms. If sql succeeds and the reset after it fails, as when
        # the timeout fires just as sql finishes, the reset's error stands in
        # for sql's result.
        def clocked(connection, sql, params, timeout_ms)
          clock, outcome, reset = run(connection, [[ARM_SQL, [timeout_ms.to_s]], [sql, params], [DISARM_SQL, []]])
          return [nil, clock] unless clock.result_status == PG::PGRES_TUPLES_OK

          [Float(clock.getvalue(0, 0)), failed?(reset) && !failed?(outcome) ? reset : outcome]
        end

        # statements are [sql, params] pairs. If a send fails, what was sent
        # is still synced and read, so the connection leaves pipeline mode.
        # If the connection dies partway, it stays in pipeline mode: there's
        # nothing left to sync or read. libpq then reports its transaction
        # status as PQTRANS_UNKNOWN, so the runner sends it nothing more, and
        # a later with_fixture refuses it as connection_unusable.
        def run(connection, statements)
          sent = []
          connection.enter_pipeline_mode
          begin
            statements.each { |sql, params| sent << connection.send_query_params(sql, params) }
          ensure
            results = finish(connection, sent.size)
          end
          results
        end

        # Each statement gives one result and then nil; the Sync gives its
        # own result last. An error can come between them, after the last
        # statement's result: statement_timeout, or another cancel, that
        # fired just as the statement finished is reported on the Sync. It
        # gives its own result and nil, like a statement. It aborts the
        # transaction, so it stands in for the last statement's result, and
        # the caller sees the cancel as it would a cancel of the statement.
        # If the last statement failed on its own, its error is kept, and if
        # nothing was sent, the error is only drained, so the send's own
        # error goes up.
        def finish(connection, sent)
          connection.pipeline_sync
          results = Array.new(sent) { next_result(connection) }
          raise Broken, "the pipeline didn't end with its sync" unless synced?(take_late_error(connection, results))

          connection.exit_pipeline_mode
          results
        end

        # Reads the next result. If it's an error, it replaces the last of
        # results, unless there's none or that one failed too, and the result
        # after its nil is returned.
        def take_late_error(connection, results)
          last = connection.get_result
          return last unless failed?(last)

          results[-1] = last unless results.empty? || failed?(results[-1])
          connection.get_result
          connection.get_result
        end

        def next_result(connection) = connection.get_result.tap { connection.get_result }

        def synced?(result) = result&.result_status == PG::PGRES_PIPELINE_SYNC

        def failed?(result) = result&.result_status == PG::PGRES_FATAL_ERROR
      end
    end
  end
end
