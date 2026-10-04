# frozen_string_literal: true

require_relative "../rewrite_entry"
require_relative "../literal_set"
require_relative "../measurement"
require_relative "../production_comparison"
require_relative "../redaction"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks result-comparison --run <run ID>` (DESIGN.md's result-comparison): on the
      # racetrack, for each literals literal set, compares anchored_query's result
      # with each candidate's that candidate_runs measured, with
      # ProductionComparison, binding the set's literals as Measurement
      # does, under the baseline's timeout_ms. Results don't depend on which
      # indexes are visible, so none are shown or hidden. It writes
      # result_comparison:
      #   "verdicts"      { "rewrite_<n>" => { set name => { "result" =>
      #                   "pass" | "fail" | "partial", "rule" => name or nil } } }
      #   "discarded"     the candidates with any failing verdict: a real
      #                   divergence on production data, which selection drops
      #                   and the report shows prominently
      #   "partial_count" how many verdicts were partial, for the report
      # Rows never leave the enclave, and nothing but DONE goes out.
      module ResultComparison
        module_function

        def call(store:, **)
          connection = Enclave::RunServer.connect(store, :racetrack)
          store.write("result_comparison", entry(verdicts(store, connection)))
          []
        ensure
          connection&.close
        end

        def entry(verdicts)
          all = verdicts.values.flat_map(&:values)
          { "verdicts" => verdicts,
            "discarded" => verdicts.select { |_, sets| sets.values.any? { it["result"] == "fail" } }.keys,
            "partial_count" => all.count { it["result"] == "partial" } }
        end

        def verdicts(store, connection)
          timeout_ms = store.read("baseline").fetch("timeout_ms")
          original = store.read("anchored_query")
          sets = LiteralSet.load(store).sets
          store.read("candidate_runs")["candidates"].keys.to_h do |search|
            sql = RewriteEntry.run_sql(store.read(search))
            [search, sets.to_h { |set, map| [set, verdict(connection, original, sql, map, timeout_ms)] }]
          end
        end

        def verdict(connection, original, candidate, map, timeout_ms)
          bound_original = Redaction.binding(original, map)
          bound_candidate = Redaction.binding(candidate, map)
          params = Measurement.params(connection, bound_original)
          ProductionComparison.compare(connection:, original: bound_original.sql, candidate: bound_candidate.sql,
                                       params:, timeout_ms:).to_h.transform_keys(&:to_s)
        end
      end
    end
  end
end
