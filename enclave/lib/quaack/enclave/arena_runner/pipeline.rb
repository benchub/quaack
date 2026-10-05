# frozen_string_literal: true

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
      module Pipeline
        # libpq's ExecStatusType values, since the runner names no PG
        # constant.
        PGRES_TUPLES_OK = 2
        PGRES_FATAL_ERROR = 7
        PGRES_PIPELINE_SYNC = 10

        class Broken < StandardError; end

        module_function

        # The server's clock, in ms, read just before sql, in sql's round
        # trip, and the result to check: sql's, or the clock read's if that
        # failed, with no clock then.
        def clocked(connection, sql, params)
          clock, outcome = run(connection, [[ServerClock::NOW_SQL, []], [sql, params]])
          return [nil, clock] unless clock.result_status == PGRES_TUPLES_OK

          [Float(clock.getvalue(0, 0)), outcome]
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
        def finish(connection, sent)
          connection.pipeline_sync
          results = Array.new(sent) { next_result(connection) }
          raise Broken, "the pipeline didn't end with its sync" unless synced?(take_late_error(connection, results))

          connection.exit_pipeline_mode
          results
        end

        # Reads the next result. If it's an error, it replaces the last of
        # results, and the result after its nil is returned.
        def take_late_error(connection, results)
          last = connection.get_result
          return last unless failed?(last)

          results[-1] = last
          connection.get_result
          connection.get_result
        end

        def next_result(connection) = connection.get_result.tap { connection.get_result }

        def synced?(result) = result&.result_status == PGRES_PIPELINE_SYNC

        def failed?(result) = result&.result_status == PGRES_FATAL_ERROR
      end
    end
  end
end
