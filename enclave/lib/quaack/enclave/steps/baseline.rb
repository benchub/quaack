# frozen_string_literal: true

require_relative "../measurement"
require_relative "../run_discipline"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks baseline --run <run ID>` (README 13, 12b): on the racetrack,
      # with every index index-build built hidden, measures anchored_query
      # for each 3e literal set (Measurement, combination nil).
      #
      # The first run's statement_timeout comes from the production
      # EXPLAIN ANALYZE of step 1: RunDiscipline.timeout_ms of the stored
      # plan's Execution Time. That's the only baseline there is before the
      # racetrack has run the query. It writes baseline:
      #   "sets"       { set name => measurement, as Measurement gives it }
      #   "timed_out"  the set names whose runs timed out
      #   "timeout_ms" for 13a and 14: RunDiscipline.timeout_ms of the
      #                slowest racetrack baseline run (or the first
      #                timeout, if every set timed out)
      # Its only line is DONE.
      module Baseline
        module_function

        def call(store:, **)
          connection = Enclave::RunServer.connect(store, :racetrack)
          first = RunDiscipline.timeout_ms(store.read("plan")[0].fetch("Execution Time"))
          sets = Measurement.measure(connection:, store:, sql: store.read("anchored_query"), combination: nil,
                                     timeout_ms: first)
          store.write("baseline", entry(sets, first))
          []
        ensure
          connection&.close
        end

        def entry(sets, first)
          times = sets.values.reject { it["timed_out"] }.flat_map { it["runs"] }.map { it["execution_ms"] }
          { "sets" => sets, "timed_out" => sets.select { |_, m| m["timed_out"] }.keys,
            "timeout_ms" => times.empty? ? first : RunDiscipline.timeout_ms(times.max) }
        end
      end
    end
  end
end
