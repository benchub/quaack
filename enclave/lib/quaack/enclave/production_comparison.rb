# frozen_string_literal: true

require "digest"
require "json"
require "pg"
require_relative "result_comparator"
require_relative "result_comparison"
require_relative "run_discipline"

module Quaack
  module Enclave
    # README 14c: compares the original's result with a candidate's on the
    # racetrack, with 9d's rules (ResultComparison, ResultComparator), but
    # without holding rows. Each query runs as a plain query, alone, in a
    # READ ONLY transaction under statement_timeout (RunDiscipline's lock),
    # with params bound, and its rows stream in single-row mode.
    #
    #   ProductionComparison.compare(connection:, original:, candidate:, params:, timeout_ms:)
    #   # => Verdict(result: "pass" | "fail" | "partial", rule: nil | String)
    #
    # Each row is hashed (SHA-256) from ResultComparator::Values.key, which
    # rounds float columns to eight significant digits (and to zero below
    # 1e-12) and is exact for every other type. So float noise within 9d's
    # tolerance hashes the same, except across a rounding boundary, which
    # says mismatch. A result's digest hashes its row count together with
    # its row hashes: sorted, for a multiset, or in order, for an ordered
    # comparison.
    #
    # Modes, as 9d picks them from the original's top level:
    # - multiset: the column types, row counts, and sorted digests match.
    # - ordered: 9d's tiebreaker runs, T and T', on both queries, and the
    #   same refusals apply (unsupported_order): the original's T and T'
    #   sorted digests must match, and when a column is left out of the
    #   tiebreaker, no two of the original's rows may agree on every
    #   tiebreaker column but differ in a left-out one. Then the
    #   candidate's T and T' ordered digests must match the original's.
    # - subset (LIMIT or OFFSET, no ORDER BY): the original as written gives
    #   the expected count. The candidate's row hashes, which number at most
    #   that, are tallied, and the original without its LIMIT streams past
    #   them, each row taking one. Every candidate row must be taken. If
    #   the full original times out, only the count is checked, and a match
    #   is partial, rule subset_timed_out.
    # - with_ties: unsupported_order, nothing run.
    #
    # Any other timeout fails, rule timed_out.
    #
    # Trust boundary. A Verdict holds only a fixed result word and a rule
    # name. Row values live only as hashes inside one compare.
    module ProductionComparison
      RESULTS = %w[pass fail partial].freeze
      RULES = [*ResultComparator::RULES.map(&:to_s), "timed_out", "subset_timed_out"].freeze

      Verdict = Data.define(:result, :rule) do
        def initialize(result:, rule:)
          raise ArgumentError, "a verdict's result must be one of RESULTS" unless RESULTS.include?(result)
          raise ArgumentError, "a verdict's rule must be one of RULES, or nil" unless rule.nil? || RULES.include?(rule)

          super
        end
      end

      # A streamed result: its column types, row count, and digests.
      # hidden is whether rows agree on the tie columns but differ in the
      # others (only when tie columns were given).
      Digested = Data.define(:types, :count, :sorted, :ordered, :hidden)

      class TimedOut < StandardError; end

      # A ResultComparison-shaped transaction for the catalog lookups,
      # which take no params.
      Catalog = Struct.new(:connection) do
        def query(sql)
          result = connection.exec(sql)
          ArenaRunner::Result.new(columns: result.fields, types: result.nfields.times.map { result.ftype(it) },
                                  rows: result.values)
        end
      end

      module_function

      def compare(connection:, original:, candidate:, params:, timeout_ms:)
        run = Run.new(connection, params, timeout_ms)
        original_shape = ResultComparison::Shape.parse(original, :original)
        candidate_shape = ResultComparison::Shape.parse(candidate, :candidate)
        case original_shape.mode
        when :multiset then multiset(run, original, candidate)
        when :subset then subset(run, original_shape, original, candidate)
        when :with_ties then fail("unsupported_order")
        else
          candidate_shape.ordered? ? ordered(run, original_shape, candidate_shape) : fail("candidate_unordered")
        end
      rescue TimedOut
        fail("timed_out")
      end

      def pass = Verdict.new(result: "pass", rule: nil)
      def fail(rule) = Verdict.new(result: "fail", rule:)

      def shape_rule(expected, actual)
        return "column_count" if expected.types.size != actual.types.size

        "column_types" if expected.types != actual.types
      end

      def multiset(run, original, candidate)
        expected = run.digest(original)
        actual = run.digest(candidate)
        rule = shape_rule(expected, actual)
        rule ||= "row_count" if expected.count != actual.count
        rule ||= "multiset" if expected.sorted != actual.sorted
        rule ? fail(rule) : pass
      end

      def subset(run, original_shape, original, candidate)
        expected = run.digest(original)
        tally = Hash.new(0)
        actual = run.digest(candidate) { tally[it] += 1 }
        rule = shape_rule(expected, actual)
        rule ||= "row_count" if expected.count != actual.count
        return fail(rule) if rule

        taken = take(run, original_shape.without_limit, tally)
        return Verdict.new(result: "partial", rule: "subset_timed_out") if taken.nil?

        taken ? pass : fail("subset")
      end

      # Whether the full result's rows take every tallied row; nil when it
      # times out.
      def take(run, sql, tally)
        run.digest(sql) do |hash|
          next unless tally.key?(hash)

          tally[hash] -= 1
          tally.delete(hash) if tally[hash].zero?
        end
        tally.empty?
      rescue TimedOut
        nil
      end

      def ordered(run, original_shape, candidate_shape)
        expected = run.digest(original_shape.probe)
        rule = shape_rule(expected, run.digest(candidate_shape.probe))
        return fail(rule) if rule

        positions = positions(run, original_shape, candidate_shape, expected.types)
        return fail("unsupported_order") unless positions

        originals = [false, true].map { run.digest(original_shape.with_tiebreaker(positions, descending: it), positions) }
        return fail("unsupported_order") if originals[0].sorted != originals[1].sorted || originals[0].hidden

        tiebroken(run, originals, candidate_shape, positions)
      end

      def positions(run, original_shape, candidate_shape, types)
        catalog = Catalog.new(run.connection)
        shapes = [original_shape, candidate_shape]
        tiebreaker = ResultComparison::Tiebreaker
        return if tiebreaker.nondeterministic_collation?(catalog, shapes.flat_map(&:collation_names))

        positions = tiebreaker.positions(types, tiebreaker.catalog_orderable(catalog, types))
        positions if positions.size == types.size || shapes.none?(&:cut?)
      end

      def tiebroken(run, originals, candidate_shape, positions)
        originals.zip([false, true]).each do |original, descending|
          actual = run.digest(candidate_shape.with_tiebreaker(positions, descending:))
          return fail("row_count") if actual.count != original.count
          return fail("value") if actual.ordered != original.ordered
        end
        pass
      end

      # Runs queries for one compare.
      class Run
        attr_reader :connection

        def initialize(connection, params, timeout_ms)
          @connection = connection
          @params = params
          @timeout_ms = Integer(timeout_ms)
        end

        # Streams sql's rows into a Digested. Yields each row's hash.
        # tie_positions, 1-based, turn on the hidden check.
        def digest(sql, tie_positions = nil, &)
          RunDiscipline::LOCK.synchronize do
            @connection.exec("BEGIN READ ONLY")
            begin
              @connection.exec("SET LOCAL statement_timeout = #{@timeout_ms}")
              stream(sql, tie_positions, &)
            ensure
              @connection.exec("ROLLBACK")
            end
          end
        end

        private

        def stream(sql, tie_positions)
          started = now
          hashes = []
          types = nil
          ties = {}
          hidden = false
          @connection.send_query_params(sql, @params)
          @connection.set_single_row_mode
          begin
            while (result = @connection.get_result)
              result.check
              types ||= result.nfields.times.map { result.ftype(it) }
              result.each_row do |row|
                key = ResultComparator::Values.key(types, row)
                hash = Digest::SHA256.digest(JSON.generate(key))
                hashes << hash
                yield hash if block_given?
                hidden ||= hidden?(ties, key, tie_positions) if tie_positions
              end
            end
          rescue PG::QueryCanceled
            drain
            raise if now - started < @timeout_ms

            raise TimedOut
          end
          count = hashes.size
          Digested.new(types:, count:, sorted: Digest::SHA256.digest("#{count}:#{hashes.sort.join}"),
                       ordered: Digest::SHA256.digest("#{count}:#{hashes.join}"), hidden:)
        end

        def hidden?(ties, key, positions)
          kept = positions.map(&:pred)
          tie = kept.map { key[it] }
          rest = key.each_index.reject { kept.include?(it) }.map { key[it] }
          ties.fetch(tie) { ties[tie] = rest } != rest
        end

        def drain
          while @connection.get_result; end
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end
    end
  end
end
