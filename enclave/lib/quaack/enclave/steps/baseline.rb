# frozen_string_literal: true

require_relative "../measurement"
require_relative "../run_discipline"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks baseline --run <run ID>` (DESIGN.md's baseline, run-discipline): on the racetrack,
      # with every index that index-build built hidden, measures anchored_query
      # for each literal set (Measurement, combination nil).
      #
      # The original gets up to 15 minutes per run (ORIGINAL_TIMEOUT_MS), not
      # the 3x clamp; a set that still times out counts as infinite in minimax.
      # It writes baseline:
      #   "sets"       { set name => measurement, as Measurement gives it }
      #   "timed_out"  the set names whose runs timed out
      #   "timeout_ms" for index-baseline and candidate-runs: RunDiscipline.timeout_ms of the
      #                slowest racetrack baseline run (or MAX_MS, if every
      #                set timed out)
      #   "measurement_runs" how many runs it took (Measurement.runs), for the burndown
      # Its only line is DONE.
      module Baseline
        ORIGINAL_TIMEOUT_MS = 900_000

        module_function

        def call(store:, **)
          connection = Enclave::RunServer.connect(store, :racetrack)
          sets = Measurement.measure(connection:, store:, sql: store.read("anchored_query"), combination: nil,
                                     timeout_ms: ORIGINAL_TIMEOUT_MS)
          store.write("baseline", entry(sets))
          []
        ensure
          connection&.close
        end

        def entry(sets)
          times = sets.values.reject { it["timed_out"] }.flat_map { it["runs"] }.map { it["execution_ms"] }
          { "sets" => sets, "timed_out" => sets.select { |_, m| m["timed_out"] }.keys,
            "timeout_ms" => times.empty? ? RunDiscipline::MAX_MS : RunDiscipline.timeout_ms(times.max),
            "measurement_runs" => Measurement.runs(sets) }
        end
      end
    end
  end
end
