# frozen_string_literal: true

require_relative "../config"
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
      # The original gets up to the config's baseline_cap_ms per run (one
      # hour without one), not the 3x clamp. If any run hits it, baseline
      # refuses as baseline_original_exceeded_cap and writes nothing.
      # It writes baseline:
      #   "sets"       { set name => measurement, as Measurement gives it }
      #   "timed_out"  the set names whose runs timed out
      #   "timeout_ms" for index-baseline and candidate-runs: RunDiscipline.timeout_ms of the
      #                slowest racetrack baseline run (or MAX_MS, if every
      #                set timed out)
      #   "measurement_runs" how many runs it took (Measurement.runs), for the burndown
      # It sends one step_counts: sets, how many literal sets it measured,
      # and timed_out, how many of those timed out. Then DONE.
      module Baseline
        class Error < StandardError
          attr_reader :rule

          def initialize(rule)
            @rule = rule
            super
          end
        end

        module_function

        def call(store:, config: Config.load, **)
          connection = Enclave::RunServer.connect(store, :racetrack)
          sets = Measurement.measure(connection:, store:, sql: store.read("anchored_query"), combination: nil,
                                     timeout_ms: config.baseline_cap_ms)
          raise Error, "baseline_original_exceeded_cap" if sets.values.any? { it["timed_out"] }

          entry = entry(sets)
          store.write("baseline", entry)
          [{ type: :step_counts, sets: sets.size, timed_out: entry["timed_out"].size }]
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
