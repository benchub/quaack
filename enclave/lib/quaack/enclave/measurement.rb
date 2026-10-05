# frozen_string_literal: true

require "json"
require_relative "index_build"
require_relative "literal_set"
require_relative "redaction"
require_relative "run_discipline"

module Quaack
  module Enclave
    # DESIGN.md's baseline (and index-baseline, candidate-runs): the measurement process. For each literal
    # set, runs sql three times with EXPLAIN (ANALYZE, BUFFERS, TIMING OFF,
    # FORMAT JSON) under RunDiscipline, with only one index combination
    # visible among index_build's indexes.
    #
    #   Measurement.measure(connection:, store:, sql:, combination:, timeout_ms:)
    #   # => { set name => measurement }
    #
    # combination is an index_build combination key, or nil to hide every
    # built index (the baseline). sql is written with redact's placeholders
    # (anchored_query or a rewrite) and is bound with each set's literals
    # through PREPARE, never spliced in. A measurement is either
    # { "timed_out" => true }, when any of the three runs hit
    # statement_timeout (the caller drops that candidate and counts it), or:
    #   "runs"         [{ "total_blocks", "hit", "read", "execution_ms" }]
    #   "stable"       whether total_blocks was the same in all three runs
    #   "total_blocks" the max of the three (for an unstable literal, blocks-metric and
    #                  minimax use the max)
    #   "plans"        only when unstable: each run's plan, redacted through
    #                  redact against that set's literals
    # total_blocks is shared hit + read, local hit + read, and temp read +
    # written, from the top plan node (its counts include its children).
    # hit is shared + local hit; read is the rest.
    #
    # The plans are redacted, but the store keeps all of it anyway: nothing
    # here goes out.
    module Measurement
      RUNS = 3
      STATEMENT = "quaack_measure"
      HIT = ["Shared Hit Blocks", "Local Hit Blocks"].freeze
      READ = ["Shared Read Blocks", "Local Read Blocks", "Temp Read Blocks", "Temp Written Blocks"].freeze

      module_function

      def measure(connection:, store:, sql:, combination:, timeout_ms:)
        build = store.read("index_build")
        LiteralSet.load(store).sets.to_h do |set, map|
          bound = Redaction.binding(sql, map)
          params = params(connection, bound)
          show(connection, build, combination, bound.sql, params)
          [set, measure_set(connection, bound, params, map, timeout_ms)]
        end
      end

      def measure_set(connection, bound, params, map, timeout_ms)
        sql = "EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) #{bound.sql}"
        runs = RUNS.times.map do
          run = RunDiscipline.run(connection:, sql:, params:, timeout_ms:)
          return { "timed_out" => true } if run.timed_out

          JSON.parse(run.result.getvalue(0, 0))
        end
        summarize(runs, map)
      end

      # The values as bound parameters, never in the SQL's text, each with
      # the type OID Postgres gave it when Binding#prepare declared the
      # types, so each $n is typed as its literal was. The prepared
      # statement is only for that.
      def params(connection, bound)
        bound.prepare(connection, STATEMENT)
        oids = PG::TextDecoder::Array.new.decode(connection.exec_params(
          "SELECT parameter_types::oid[]::text[] FROM pg_prepared_statements WHERE name = $1", [STATEMENT]
        ).getvalue(0, 0))
        bound.values.zip(oids).map { |value, oid| { value:, type: Integer(oid) } }
      ensure
        connection.exec("DEALLOCATE #{STATEMENT}") if prepared?(connection)
      end

      def show(connection, build, combination, sql, params)
        return IndexBuild.show_only(connection, build, combination, sql:, params:) if combination

        IndexBuild.hide_all(connection, build)
        IndexBuild.confirm(connection, build, [], sql:, params:)
      end

      def prepared?(connection)
        connection.exec_params("SELECT 1 FROM pg_prepared_statements WHERE name = $1", [STATEMENT]).ntuples.positive?
      end

      # The measurement for three parsed EXPLAIN JSON outputs.
      def summarize(runs, map)
        counts = runs.map { counts(it) }
        totals = counts.map { it["total_blocks"] }
        out = { "timed_out" => false, "runs" => counts, "stable" => totals.uniq.size == 1,
                "total_blocks" => totals.max }
        out["plans"] = runs.map { Redaction.plan(it, map).explain } unless out["stable"]
        out
      end

      def counts(explain)
        top = explain[0]["Plan"]
        hit = HIT.sum { top.fetch(it, 0) }
        read = READ.sum { top.fetch(it, 0) }
        { "total_blocks" => hit + read, "hit" => hit, "read" => read, "execution_ms" => explain[0]["Execution Time"] }
      end
    end
  end
end
