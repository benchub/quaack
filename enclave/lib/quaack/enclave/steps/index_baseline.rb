# frozen_string_literal: true

require_relative "../index_build"
require_relative "../measurement"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-baseline --run <run ID>` (DESIGN.md 13a): on the
      # racetrack, measures anchored_query under each of the original's
      # index_build combinations (the ones 5a kept), with baseline's
      # timeout_ms. It writes index_baseline:
      #   "combinations" { combination key => { set name => measurement } }
      #   "timed_out"    the combination keys where any set timed out
      # Every built index is hidden again at the end. Its only line is DONE.
      module IndexBaseline
        module_function

        def call(store:, **)
          connection = Enclave::RunServer.connect(store, :racetrack)
          build = store.read("index_build")
          results = measure_all(connection, store, build["combinations"].keys.grep(/\Aoriginal:/))
          store.write("index_baseline", "combinations" => results,
                                        "timed_out" => results.select { |_, s| s.values.any? { it["timed_out"] } }.keys)
          []
        ensure
          Enclave::IndexBuild.hide_all(connection, build) if connection && build
          connection&.close
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
