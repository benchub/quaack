# frozen_string_literal: true

require "digest"
require "json"
require "pg"
require_relative "result_comparator"
require_relative "result_comparison"
require_relative "run_discipline"
require_relative "server_clock"

module Quaack
  module Enclave
    # DESIGN.md's result-comparison: compares the original's result with a candidate's on the
    # racetrack, with fixture-compare's rules (ResultComparison, ResultComparator), but
    # without holding rows. Each query runs as a plain query, alone, in a
    # READ ONLY transaction under statement_timeout (RunDiscipline's lock),
    # with params bound, and its rows stream in single-row mode.
    #
    #   ProductionComparison.compare(connection:, original:, candidate:, params:, timeout_ms:)
    #   # => Verdict(result: "pass" | "fail" | "partial", rule: nil | String)
    #
    # Each row is hashed (SHA-256) from ResultComparator::Values.key, which
    # rounds float columns to eight significant digits (and to zero below
    # 1e-12) and is exact for every other type. So float noise within fixture-compare's
    # tolerance hashes the same, except across a rounding boundary, which
    # says mismatch. A result's digest hashes its row count together with
    # its row hashes: sorted, for a multiset, or in order, for an ordered
    # comparison.
    #
    # Modes, as fixture-compare picks them from the original's top level:
    # - multiset: the column types, row counts, and sorted digests match.
    # - ordered: fixture-compare's tiebreaker runs, T and T', on both queries, and the
    #   same refusals apply (unsupported_order): when a column is left out
    #   of the tiebreaker, no two of the original's rows may agree on every
    #   tiebreaker column but differ in a left-out one. When the original's
    #   T and T' sorted digests match, and either it has no LIMIT and
    #   OFFSET together or its runs through the end of the window
    #   (Shape#through_window) match too, the candidate's T and T' ordered
    #   digests must match the original's. Otherwise a LIMIT or OFFSET may
    #   cut a tie group, and ResultComparison::CutTies checks the candidate
    #   on row hashes, from both queries' runs with and without their LIMIT
    #   and OFFSET, as fixture-compare does (HashedRuns). A run without a
    #   LIMIT that times out refuses, unsupported_order.
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
      # hashes are the row hashes, in order.
      Digested = Data.define(:types, :count, :sorted, :ordered, :hidden, :hashes)

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
        by_mode(Run.new(connection, params, timeout_ms), original, candidate)
      rescue TimedOut
        fail("timed_out")
      end

      def by_mode(run, original, candidate)
        original_shape = ResultComparison::Shape.parse(original, :original)
        candidate_shape = ResultComparison::Shape.parse(candidate, :candidate)
        case original_shape.mode
        when :multiset then multiset(run, original, candidate)
        when :subset then subset(run, original_shape, original, candidate)
        when :with_ties then fail("unsupported_order")
        else
          candidate_shape.ordered? ? ordered(run, original_shape, candidate_shape) : fail("candidate_unordered")
        end
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
        originals = positions && tiebreaker_runs(run, original_shape, positions)
        return fail("unsupported_order") if originals.nil? || originals.first.hidden

        HashedRuns.new(run, positions).verdict([original_shape, candidate_shape], originals)
      end

      def tiebreaker_runs(run, shape, positions)
        [false, true].map { run.digest(shape.with_tiebreaker(positions, descending: it), positions) }
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

      # The candidate's verdict from the original's tiebreaker runs: they
      # match row for row, or, when CutTies.needed?, ResultComparison::CutTies'
      # check runs on row hashes, with this class as its source. Its runs
      # without a LIMIT keep only row hashes, and when one times out, the
      # comparison refuses with unsupported_order, as it did before the
      # check could recover a tie at a cut.
      class HashedRuns
        def initialize(run, positions)
          @run = run
          @positions = positions
        end

        def verdict(shapes, originals)
          return ProductionComparison.tiebroken(@run, originals, shapes.last, @positions) unless cut?(shapes, originals)

          @columns = originals.first.types.size
          rule, = catch(:full_timed_out) { ResultComparison::CutTies.check(shapes, originals.map(&:hashes), self) }
          rule ? ProductionComparison.fail(rule.to_s) : ProductionComparison.pass
        end

        def fetch(shape, limited:)
          [false, true].map do |descending|
            @run.digest(shape.with_tiebreaker(@positions, descending:, limited:)).hashes
          rescue TimedOut
            raise if limited

            throw :full_timed_out, ResultComparison::CutTies::REFUSED
          end
        end

        def key(row) = row
        def contained?(big, small) = ResultComparison::CutTies.tallied?(big, small)
        def all_columns? = @positions.size == @columns

        private

        def cut?(shapes, originals)
          uncut = originals.map(&:sorted).uniq.one?
          ResultComparison::CutTies.needed?(shapes.first, uncut:, kept_rows: originals.first.hashes.any?) do
            [false, true].map { @run.digest(shapes.first.through_window(@positions, descending: it)).sorted }.uniq.one?
          end
        end
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
              started = ServerClock.mark(@connection, "SET LOCAL statement_timeout = #{@timeout_ms};")
              stream(sql, tie_positions, started, &)
            ensure
              @connection.exec("ROLLBACK")
            end
          end
        end

        private

        # A cancel is a timeout only if timeout_ms has passed since started
        # on the server's clock, the one statement_timeout fires by. The
        # jump server's clock can run at another rate.
        def stream(sql, tie_positions, started, &)
          rows = Rows.new(tie_positions)
          @connection.send_query_params(sql, @params)
          @connection.set_single_row_mode
          read(rows, &)
          rows.digested
        rescue PG::QueryCanceled
          drain
          raise unless ServerClock.timed_out?(@connection, started, @timeout_ms)

          raise TimedOut
        end

        def read(rows, &)
          while (result = @connection.get_result)
            result.check
            rows.add(result, &)
          end
        end

        def drain
          while @connection.get_result; end
        end
      end

      # Row hashes gathered from one query.
      class Rows
        def initialize(tie_positions)
          @kept = tie_positions&.map(&:pred)
          @hashes = []
          @ties = {}
          @hidden = false
        end

        def add(result)
          @types ||= result.nfields.times.map { result.ftype(it) }
          result.each_row do |row|
            key = ResultComparator::Values.key(@types, row)
            hash = Digest::SHA256.digest(JSON.generate(key))
            @hashes << hash
            yield hash if block_given?
            @hidden ||= hidden?(key) if @kept
          end
        end

        def digested
          count = @hashes.size
          Digested.new(types: @types, count:, sorted: Digest::SHA256.digest("#{count}:#{@hashes.sort.join}"),
                       ordered: Digest::SHA256.digest("#{count}:#{@hashes.join}"), hidden: @hidden,
                       hashes: @hashes)
        end

        private

        # Whether key agrees with an earlier row on the tie columns but
        # differs in another.
        def hidden?(key)
          tie = @kept.map { key[it] }
          rest = key.each_index.reject { @kept.include?(it) }.map { key[it] }
          @ties.fetch(tie) { @ties[tie] = rest } != rest
        end
      end
    end
  end
end
