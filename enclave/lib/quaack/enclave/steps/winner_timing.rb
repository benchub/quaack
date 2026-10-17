# frozen_string_literal: true

require_relative "../rewrite_entry"
require_relative "../index_build"
require_relative "../measurement"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks winner-timing --run <run ID>` (DESIGN.md's winner-timing): on
      # the racetrack, once selection is stored, runs the winner (selection's
      # first top entry) once on the slow values with timing on
      # (Measurement.timed), under its own index combination and baseline's
      # timeout_ms, so the report can show where its time went. It writes
      # winner_timing:
      #   "label"  the winner's label, or nil with no winner
      #   "result" Measurement.timed's result, or nil with no winner
      #   "plan"   the run's redacted plan, or nil unless result is timed
      # With no winner it connects to nothing. Every built index is hidden
      # again at the end. It sends only DONE.
      module WinnerTiming
        module_function

        def call(store:, **)
          label = store.read("selection")["top"].first&.fetch("label")
          store.write("winner_timing", { "label" => label, **(label ? time(store, label) : none) })
          []
        end

        def none = { "result" => nil, "plan" => nil }

        def time(store, label)
          connection = Enclave::RunServer.connect(store, :racetrack)
          search, = label.split(":")
          Measurement.timed(connection:, store:, sql: sql(store, search), combination: combination(label),
                            timeout_ms: store.read("baseline").fetch("timeout_ms"))
        ensure
          if connection
            Enclave::IndexBuild.hide_all(connection, store.read("index_build"))
            connection.close
          end
        end

        def sql(store, search)
          search == "original" ? store.read("anchored_query") : RewriteEntry.run_sql(store.read(search))
        end

        # The label's index combination key, or nil to hide every built
        # index for <search>:none, as MeasuredLabels reads them.
        def combination(label) = label.end_with?(":none") ? nil : label
      end
    end
  end
end
