# frozen_string_literal: true

require "json"
require_relative "index_build"
require_relative "literal_set"
require_relative "plain_data"
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
    # { "timed_out" => true, "ran" => <runs up to and including the one
    # that timed out> }, when any of the three runs hit statement_timeout
    # (the caller drops that candidate and counts it), or:
    #   "runs"         [{ "total_blocks", "hit", "read", "execution_ms" }]
    #   "stable"       whether total_blocks was the same in all three runs
    #   "total_blocks" the max of the three (for an unstable literal, blocks-metric and
    #                  minimax use the max)
    #   "plans"        the runs' plans, each redacted through redact against
    #                  that set's literals: when unstable, each run's plan in
    #                  run order; when stable, only the first run's
    # Measurement.plan(measurement) gives the measured plan, the plan of the
    # run with the most blocks (the first, if several tie). That's the run
    # MeasuredLabels takes hit and read from, so its top node's counts are
    # the ones the report shows. Each plan is stored once, so every reader
    # gets the measured plan through Measurement.plan.
    # total_blocks is shared hit + read, local hit + read, and temp read +
    # written, from the top plan node (its counts include its children).
    # hit is shared + local hit; read is the rest.
    #
    # The plans are redacted, but the store keeps all of it anyway: nothing
    # here goes out.
    #
    #   Measurement.timed(connection:, store:, sql:, combination:, timeout_ms:)
    #   # => { "result" => "timed" | "timed_out" | "failed", "plan" => redacted plan or nil }
    #
    # DESIGN.md's winner-timing: runs sql once on the slow set's literals with
    # EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON), timing on, the same way and
    # under the same rails as measure (the same binding, the same index
    # combination shown and confirmed, RunDiscipline's READ ONLY
    # transaction and timeout_ms). It's never one of measure's runs, so
    # timing's overhead never touches a block count that ranks anything.
    # A run that hits statement_timeout is timed_out; one that raises a
    # Postgres error or a plan too deep to read is failed, as the times are
    # only for show. Anything else, such as the wrong indexes visible, is
    # raised as it is in measure.
    module Measurement
      RUNS = 3
      STATEMENT = "quaack_measure"
      MEASURED = "EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) "
      TIMED = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) "
      TIMED_SET = "slow"
      HIT = ["Shared Hit Blocks", "Local Hit Blocks"].freeze
      READ = ["Shared Read Blocks", "Local Read Blocks", "Temp Read Blocks", "Temp Written Blocks"].freeze

      # A refusal with a fixed rule, such as plan_too_deep. Its message is
      # its rule, which ErrorFilter sends out.
      Error = Class.new(StandardError) { def rule = message }

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

      def timed(connection:, store:, sql:, combination:, timeout_ms:)
        map = LiteralSet.load(store).sets.to_h.fetch(TIMED_SET)
        bound = Redaction.binding(sql, map)
        params = params(connection, bound)
        show(connection, store.read("index_build"), combination, bound.sql, params)
        timed_run(connection, bound, params, map, timeout_ms)
      end

      def timed_run(connection, bound, params, map, timeout_ms)
        run = RunDiscipline.run(connection:, sql: "#{TIMED}#{bound.sql}", params:, timeout_ms:)
        return { "result" => "timed_out", "plan" => nil } if run.timed_out

        { "result" => "timed", "plan" => Redaction.plan(parse(run.result.getvalue(0, 0)), map).explain }
      rescue PG::Error, Error
        { "result" => "failed", "plan" => nil }
      end

      def measure_set(connection, bound, params, map, timeout_ms)
        sql = "#{MEASURED}#{bound.sql}"
        runs = RUNS.times.map do |i|
          run = RunDiscipline.run(connection:, sql:, params:, timeout_ms:)
          return { "timed_out" => true, "ran" => i + 1 } if run.timed_out

          parse(run.result.getvalue(0, 0))
        end
        summarize(runs, map)
      end

      # A deep plan nests past JSON's default limit of 100 (two levels a
      # node), so the bound is PlainData::MAX_DEPTH. Past it is a refusal
      # that carries nothing from the plan.
      def parse(json)
        JSON.parse(json, max_nesting: PlainData::MAX_DEPTH)
      rescue JSON::NestingError
        raise Error, "plan_too_deep", cause: nil
      end

      # How many EXPLAIN ANALYZE runs measure's { set name => measurement }
      # took, for the burndown's measurement_runs.
      def runs(sets) = sets.values.sum { it["timed_out"] ? it.fetch("ran", 0) : it["runs"].size }

      # The values as bound parameters, never in the SQL's text, each with
      # the type OID Postgres gave it when Binding#prepare declared the
      # types, so each $n is typed as its literal was. The prepared
      # statement is only for that.
      def params(connection, bound)
        bound.prepare(connection, STATEMENT)
        oids = PG::TextDecoder::Array.new.decode(connection.exec_params(
          "SELECT parameter_types::pg_catalog.oid[]::pg_catalog.text[] FROM pg_catalog.pg_prepared_statements " \
          "WHERE name OPERATOR(pg_catalog.=) $1", [STATEMENT]
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
        connection.exec_params("SELECT 1 FROM pg_catalog.pg_prepared_statements WHERE name OPERATOR(pg_catalog.=) $1",
                               [STATEMENT]).ntuples.positive?
      end

      # The measurement for three parsed EXPLAIN JSON outputs.
      def summarize(runs, map)
        counts = runs.map { counts(it) }
        totals = counts.map { it["total_blocks"] }
        stable = totals.uniq.size == 1
        { "timed_out" => false, "runs" => counts, "stable" => stable, "total_blocks" => totals.max,
          "plans" => (stable ? runs.take(1) : runs).map { Redaction.plan(it, map).explain } }
      end

      # A measurement's measured plan: the redacted plan of the first run
      # with the most blocks, or nil if it timed out or has no plans. A
      # stable set keeps only its first run's plan, and that run has the
      # most blocks, since every run has the same count.
      def plan(measurement)
        plans = measurement["plans"] or return
        totals = measurement["runs"].map { it["total_blocks"] }
        plans[totals.index(totals.max)]
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
