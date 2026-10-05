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
        # own result last.
        def finish(connection, sent)
          connection.pipeline_sync
          results = Array.new(sent) { connection.get_result.tap { connection.get_result } }
          raise Broken, "the pipeline didn't end with its sync" unless synced?(connection.get_result)

          connection.exit_pipeline_mode
          results
        end

        def synced?(result) = result&.result_status == PGRES_PIPELINE_SYNC
      end
    end
  end
end
