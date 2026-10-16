# frozen_string_literal: true

require "pg"
require_relative "../arena_runner"
require_relative "../result_comparator"
require_relative "../result_comparison"
require_relative "data_error"
require_relative "differ"
require_relative "signature"

module Quaack
  module Enclave
    module Fuzz
      # The search's arena transaction, and one trial in it.
      #
      #   session = Session.new(conn, catalog, [original, candidate], honour:, statement_timeout_ms:)
      #   session.open
      #   trial = session.trial(rows)   # => Trial(signature:, compared:, rule:)
      #   session.close                 # ROLLBACK
      #
      # open begins the transaction, turns index scans off (as the lift's
      # compare_in_load_orders does), has the Loader empty the footprint's
      # tables, drop the foreign keys that leave the footprint and work out
      # the honoured copies, and marks a savepoint. Each trial loads the world there, and runs EXPLAIN
      # ANALYZE of both queries for the signature, then both queries. A
      # world either query can't run on is illegal for it, judged per query:
      # a world that fails to load is illegal for both and is never
      # compared; one where the original fails is illegal for the original
      # and not compared. One where only the candidate fails is not compared
      # either, but a failure on the data (DataError) makes it a kill, by
      # query_failed, as in the counterexample rounds; a timeout or a cancel
      # doesn't.
      # Otherwise the results are compared cheaply, and on any difference,
      # or always when either query has an arbitrary pick, with the official
      # ResultComparison, whose mismatching rule
      # (ResultComparator::MISMATCHES) makes the trial a kill.
      #
      # Every RESTART trials the transaction starts again, so the rows
      # rolled-back trials leave behind, which every scan in it reads, go
      # with the files its TRUNCATE made.
      #
      # Trust boundary: a trial's world, results, and errors stay here. A
      # Trial holds only a Signature, a boolean, and a rule symbol.
      class Session
        Trial = Data.define(:signature, :compared, :rule) do
          def kill? = !rule.nil?
        end

        EXPLAIN = "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, FORMAT JSON) "
        RESTART = 500
        ILLEGAL = :illegal

        def initialize(conn, catalog, queries, honour:, statement_timeout_ms:)
          @conn = conn
          @queries = queries
          @loader = Loader.new(conn, catalog, honour)
          @timeout = statement_timeout_ms
          @mode = ResultComparison::Shape.parse(queries.first, :original).mode
          @picks = ResultComparison::Picks.any?(*queries)
          @open = false
        end

        def open
          @conn.exec("BEGIN")
          @open = true
          @since = 0
          @conn.exec("SET LOCAL statement_timeout = #{Integer(@timeout)}")
          ArenaRunner::NO_INDEX_SCANS.each { @conn.exec(it) }
          @loader.prepare
          @conn.exec("SAVEPOINT quaack_base")
        end

        def close
          return unless @open

          @open = false
          @conn.exec("ROLLBACK") unless @conn.finished?
        end

        def trial(rows)
          restart if (@since += 1) > RESTART
          return Trial.new(signature: ILLEGAL, compared: false, rule: nil) unless @loader.load(rows)

          plans, results, failed = queries
          signature = Signature.trial(*plans)
          return Trial.new(signature:, compared: false, rule: failed) unless results

          Trial.new(signature:, compared: true, rule: compare(*results))
        end

        # The indexes of sqls, loosened originals (Coverage), that give a
        # result on the arena's current data, the last trial's world, that
        # the official comparison calls a mismatch with original's (Differ).
        def differing(original, sqls) = Differ.differing(@conn, original, sqls)

        private

        def restart
          close
          open
        end

        # EXPLAIN of each query, then each query: [plans, results, failed],
        # a plan nil for a query that failed, results nil unless both ran,
        # and failed the candidate's kill (candidate_failed).
        def queries
          original, candidate = @queries
          runs = Session.batch(@conn, [EXPLAIN + original, EXPLAIN + candidate, original, candidate])
          plans = runs.first(2).map { |result, ok| ok ? result.getvalue(0, 0) : nil }
          plans[1] = nil unless runs[0].last
          [plans, runs.all?(&:last) ? runs.last(2).map(&:first) : nil, candidate_failed(runs)]
        end

        # :query_failed when the original ran and the candidate failed on
        # the data (DataError), or nil. The batch stops at its first error,
        # so the first failed run is the one that failed: 1 or 3 is the
        # candidate's, the original's EXPLAIN ANALYZE having run before it.
        def candidate_failed(runs)
          failed = runs.index { !it.last }
          return unless [1, 3].include?(failed)

          :query_failed if DataError.sqlstate?(runs[failed].first&.error_field(PG::PG_DIAG_SQLSTATE))
        end

        # Equal results are no match for certain when either query has an
        # arbitrary pick (ResultComparison::Picks), which may have gone the
        # same way here by luck, so those always go to the official one.
        def compare(original, candidate)
          return nil if !@picks && cheap_match?(original, candidate)

          @conn.exec("SAVEPOINT quaack_compare")
          verdict = official
          @conn.exec("RELEASE SAVEPOINT quaack_compare")
          verdict
        rescue PG::Error
          @conn.exec("ROLLBACK TO SAVEPOINT quaack_compare")
          nil
        end

        def official(candidate = @queries.last)
          original = @queries.first
          verdict = ResultComparison.compare(ArenaRunner::Transaction.new(method(:run_query)), original:, candidate:)
          verdict.rule if !verdict.match? && ResultComparator::MISMATCHES.include?(verdict.rule)
        end

        # Equal results in the same order, or as multisets when the
        # original's order doesn't count, are a match for certain. Anything
        # else goes to the official comparison, which knows each type's
        # equality, the order's ties, and LIMIT's cuts.
        def cheap_match?(original, candidate)
          return false unless @mode == :multiset && original.nfields == candidate.nfields

          left = original.values
          right = candidate.values
          left == right || (left.size == right.size && sorted(left) == sorted(right))
        end

        def sorted(rows) = rows.sort_by { |row| row.map { it.nil? ? [0, ""] : [1, it] } }

        def run_query(sql, _index)
          result = @conn.exec(sql)
          ArenaRunner::Result.new(columns: result.fields, types: Array.new(result.nfields) { result.ftype(it) },
                                  rows: result.values)
        end
      end
    end
  end
end

require_relative "session/loader"
