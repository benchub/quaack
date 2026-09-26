# frozen_string_literal: true

require "pg"

module Quaack
  module Enclave
    # README 12b: run discipline for measurement statements.
    #
    #   RunDiscipline.timeout_ms(baseline_ms)            # Integer
    #   RunDiscipline.run(connection:, sql:, timeout_ms:) # Run
    #
    # timeout_ms is 3x the original query's baseline time, clamped to at
    # least 5 seconds and at most 5 minutes.
    #
    # run executes sql alone in a READ ONLY transaction with
    # statement_timeout set for that transaction only, then rolls back. A
    # process-wide lock means no two statements run at once, even on
    # different connections. A statement cancelled by statement_timeout
    # comes back as a Run with timed_out true and no result; the caller
    # drops that candidate and counts it as timed out. Any other cancel,
    # such as an operator's pg_cancel_backend, is raised. sql goes through
    # the extended protocol, so SQL holding more than one statement (a
    # COMMIT that would end READ ONLY) is refused. Any other error is
    # raised, after the transaction is rolled back.
    module RunDiscipline
      MIN_MS = 5_000
      MAX_MS = 300_000
      LOCK = Mutex.new

      Run = Data.define(:result, :timed_out)

      module_function

      def timeout_ms(baseline_ms)
        (baseline_ms * 3).ceil.clamp(MIN_MS, MAX_MS)
      end

      def run(connection:, sql:, timeout_ms:)
        LOCK.synchronize do
          connection.exec("BEGIN READ ONLY")
          begin
            timed(connection, sql, timeout_ms)
          ensure
            connection.exec("ROLLBACK")
          end
        end
      end

      def timed(connection, sql, timeout_ms)
        connection.exec("SET LOCAL statement_timeout = #{Integer(timeout_ms)}")
        Run.new(result: connection.exec_params(sql, []), timed_out: false)
      rescue PG::QueryCanceled => e
        raise unless e.message.include?("statement timeout")

        Run.new(result: nil, timed_out: true)
      end
    end
  end
end
