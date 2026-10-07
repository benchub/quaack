# frozen_string_literal: true

require_relative "../index_build"
require_relative "../measurement"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-baseline --run <run ID>` (DESIGN.md's index-baseline): on the
      # racetrack, measures anchored_query under each of the original's
      # index_build combinations (the ones index-search kept), with baseline's
      # timeout_ms. It writes index_baseline:
      #   "combinations" { combination key => { set name => measurement } }
      #   "timed_out"    the combination keys where any set timed out
      #   "measurement_runs" how many runs it took (Measurement.runs), for the burndown
      # Every built index is hidden again at the end. It sends one
      # step_counts: combinations, how many it measured, and timed_out, how
      # many of those timed out. Then DONE.
      module IndexBaseline
        module_function

        def call(store:, **)
          connection = Enclave::RunServer.connect(store, :racetrack)
          build = store.read("index_build")
          results = measure_all(connection, store, build["combinations"].keys.grep(/\Aoriginal:/))
          entry = entry(results)
          store.write("index_baseline", entry)
          [{ type: :step_counts, combinations: results.size, timed_out: entry["timed_out"].size }]
        ensure
          Enclave::IndexBuild.hide_all(connection, build) if connection && build
          connection&.close
        end

        def entry(results)
          { "combinations" => results, "timed_out" => results.select { |_, s| s.values.any? { it["timed_out"] } }.keys,
            "measurement_runs" => results.values.sum { Measurement.runs(it) } }
        end

        def measure_all(connection, store, keys)
          timeout_ms = store.read("baseline").fetch("timeout_ms")
          sql = store.read("anchored_query")
          keys.to_h { [it, Measurement.measure(connection:, store:, sql:, combination: it, timeout_ms:)] }
        end
      end
    end
  end
end
