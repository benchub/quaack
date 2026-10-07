# frozen_string_literal: true

require_relative "../rewrite_entry"
require_relative "../index_build"
require_relative "../measurement"
require_relative "../run_server"
require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # `quaacks candidate-runs --run <run ID>` (DESIGN.md's candidate-runs, run-discipline): on the
      # racetrack, measures each rewrite candidate that survived rewrite-test and
      # counterexamples and wasn't pruned in plan-pruning (IndexSearch.llm_search?), first with
      # every built index hidden ("none") and then under each of its own
      # index_build combinations ("rewrite_<n>:<key>"), with Measurement and
      # the baseline's timeout_ms. A run that times out on any literal set is
      # dropped. It writes candidate_runs:
      #   "candidates"      { "rewrite_<n>" => { "none" | combination key =>
      #                       { set name => measurement } } }, only the runs
      #                       that didn't time out
      #   "timed_out"       the dropped runs, as "rewrite_<n>:none" or the
      #                     combination key
      #   "timed_out_count" how many were dropped, for the report
      #   "measurement_runs" how many runs it took (Measurement.runs), the
      #                     dropped ones' included, for the burndown
      # Every built index is hidden again at the end. It sends one
      # step_counts: measured, how many runs it measured, the dropped ones
      # included, and timed_out, how many it dropped. Then DONE.
      module CandidateRuns
        module_function

        def call(store:, **)
          connection = Enclave::RunServer.connect(store, :racetrack)
          entry = entry(store, connection)
          store.write("candidate_runs", entry)
          [{ type: :step_counts, measured: entry["candidates"].values.sum(&:size) + entry["timed_out_count"],
             timed_out: entry["timed_out_count"] }]
        ensure
          if connection
            Enclave::IndexBuild.hide_all(connection, store.read("index_build"))
            connection.close
          end
        end

        def entry(store, connection)
          timed_out = []
          counted = [0]
          candidates = candidates(store).to_h { [it, runs(store, connection, it, timed_out, counted)] }
          { "candidates" => candidates.reject { |_, runs| runs.empty? }, "timed_out" => timed_out,
            "timed_out_count" => timed_out.size, "measurement_runs" => counted.first }
        end

        # search's runs that didn't time out, by "none" or combination key.
        # Adds the label of each that did to timed_out, and how many runs
        # each took to counted's one element.
        def runs(store, connection, search, timed_out, counted)
          timeout_ms = store.read("baseline").fetch("timeout_ms")
          sql = RewriteEntry.run_sql(store.read(search))
          combinations(store, search).each_with_object({}) do |key, out|
            sets = Measurement.measure(connection:, store:, sql:, combination: key, timeout_ms:)
            counted[0] += Measurement.runs(sets)
            next timed_out << (key || "#{search}:none") if sets.values.any? { it["timed_out"] }

            out[key || "none"] = sets
          end
        end

        # nil (every built index hidden), then search's combination keys.
        def combinations(store, search)
          [nil, *store.read("index_build")["combinations"].keys.select { it.start_with?("#{search}:") }]
        end

        def candidates(store)
          (1..).lazy.take_while { store.entry?("rewrite_#{it}") }.map { "rewrite_#{it}" }
               .select { IndexSearch.llm_search?(store, it) }.to_a
        end
      end
    end
  end
end
