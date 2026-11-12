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
    #   # => Verdict(result: "pass" | "fail" | "partial", rule: nil | String,
    #   #            reason: nil | String, float_noise: true | false)
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
    #   digests must match the original's, or, when they don't, its runs'
    #   row hashes must hold each of the original's tie groups at its place,
    #   in any order (ResultComparison::Regrouped), and so must the sorted digests
    #   of its own runs through its window, when it has a LIMIT and an
    #   OFFSET. When the original's T and T' sorted digests differ with no
    #   LIMIT or OFFSET (and no DISTINCT ON), it refuses, unsupported_order
    #   with reason unstable_original (CutTies.unstable?). Since row hashes
    #   round floats, a last-bit difference across a rounding boundary does
    #   that too. Otherwise a LIMIT or OFFSET may cut a tie group, and
    #   ResultComparison::CutTies checks the candidate
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
    # Float noise (task 20261111-192302-1). A row hash can't partner floats
    # across a rounding boundary as fixture-compare does, so floats a last
    # bit apart can fail a good rewrite. The verdict stands, but when it's
    # one float noise could cause (NOISY_RULES, or unsupported_order with
    # one of NOISY_REASONS) and a result it streamed had a float column,
    # the whole compare runs a second time, under the same timeout and row
    # caps, with float columns cut to the same eight significant digits
    # on a grid shifted half a step from the first's (FloatNoise). If that
    # passes, the verdict says float_noise true, so the report can say the
    # rewrite failed on minor mismatches in float values. Any other
    # outcome of the second look, a timeout included, leaves float_noise
    # false. It's no looser than the first look: floats a step of eight
    # significant digits apart or more never pass it. A pair less than
    # half a step apart can't straddle a boundary of both grids, so it
    # passes one of them, unless it straddles a power of ten.
    #
    # Trust boundary. A Verdict holds only a fixed result word, a rule
    # name, for unsupported_order the check that refused, one of
    # Protocol::RefusalReasons, and float_noise, true or false. Row values
    # live only as hashes inside one compare.
    module ProductionComparison # rubocop:disable Metrics/ModuleLength -- one refusal per check
      RESULTS = %w[pass fail partial].freeze
      RULES = [*ResultComparator::RULES.map(&:to_s), "timed_out", "subset_timed_out"].freeze

      Verdict = Data.define(:result, :rule, :reason, :float_noise) do
        def initialize(result:, rule:, reason: nil, float_noise: false)
          raise ArgumentError, "a verdict's result must be one of RESULTS" unless RESULTS.include?(result)
          raise ArgumentError, "a verdict's rule must be one of RULES, or nil" unless rule.nil? || RULES.include?(rule)
          unless rule == "unsupported_order" ? Protocol::RefusalReasons.valid?(reason) : reason.nil?
            raise ArgumentError, "a verdict's reason must be one of Protocol::RefusalReasons on an " \
                                 "unsupported_order verdict, and nil on any other"
          end
          unless float_noise_fits?(result, float_noise)
            raise ArgumentError, "a verdict's float_noise must be true or false, and true only on a failing verdict"
          end

          super
        end

        private

        def float_noise_fits?(result, float_noise) = float_noise == false || (float_noise == true && result == "fail")
      end

      # The failures float noise can cause: a mismatch of rows, or a
      # refusal that compares row hashes (FloatNoise).
      NOISY_RULES = %w[value multiset subset].freeze
      NOISY_REASONS = %w[unstable_original cut_tie].freeze

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

      def compare(connection:, original:, candidate:, params:, timeout_ms:, binding: nil) # rubocop:disable Metrics/ParameterLists
        run = Run.new(connection, params, timeout_ms)
        verdict = strict(run, original, candidate, binding)
        return verdict unless run.floats? && noisy?(verdict)

        shifted = Run.new(connection, params, timeout_ms, shifted: true)
        strict(shifted, original, candidate, binding).result == "pass" ? verdict.with(float_noise: true) : verdict
      end

      def strict(run, original, candidate, binding)
        by_mode(run, original, candidate, binding)
      rescue TimedOut
        fail("timed_out")
      end

      # Whether float noise could explain verdict (see FloatNoise).
      def noisy?(verdict)
        NOISY_RULES.include?(verdict.rule) || (verdict.rule == "unsupported_order" &&
                                               NOISY_REASONS.include?(verdict.reason))
      end

      def by_mode(run, original, candidate, binding)
        original_shape = ResultComparison::Shape.parse(original, :original, binding:)
        candidate_shape = ResultComparison::Shape.parse(candidate, :candidate, binding:)
        case original_shape.mode
        when :multiset then multiset(run, original, candidate)
        when :subset then subset(run, original_shape, original, candidate)
        when :with_ties then refused("with_ties")
        else
          candidate_shape.ordered? ? ordered(run, original_shape, candidate_shape) : fail("candidate_unordered")
        end
      end

      def pass = Verdict.new(result: "pass", rule: nil)
      def fail(rule) = Verdict.new(result: "fail", rule:)
      def refused(reason) = Verdict.new(result: "fail", rule: "unsupported_order", reason:)

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
        return total_ordered(run, original_shape, candidate_shape) if positions == :total
        return positions if positions.is_a?(Verdict)

        originals = tiebreaker_runs(run, original_shape, positions)
        return refused("hidden_tie") unless originals

        HashedRuns.new(run, positions).verdict([original_shape, candidate_shape], originals)
      end

      def tiebreaker_runs(run, shape, positions)
        runs = [false, true].map { run.digest(shape.with_tiebreaker(positions, descending: it), positions) }
        runs unless runs.first.hidden
      end

      def positions(run, original_shape, candidate_shape, types)
        catalog = Catalog.new(run.connection)
        shapes = [original_shape, candidate_shape]
        gate = ResultComparison::TotalOrder.gate(catalog, shapes, types)
        return gate || refused("nondeterministic_collation") unless gate == :none

        tiebreaker = ResultComparison::Tiebreaker

        positions = tiebreaker.positions(types, tiebreaker.catalog_orderable(catalog, types))
        positions.size == types.size || shapes.none?(&:cut?) ? positions : refused("hidden_tie")
      end

      # The original's order is total (ResultComparison::TotalOrder), so
      # the two runs compare by ordered digest.
      def total_ordered(run, *shapes) = ordered_rule(*shapes.map { run.digest(it.sql) }).then { it ? fail(it) : pass }

      # The rule for a candidate's run that doesn't match the original's
      # in order, or nil.
      def ordered_rule(original, actual)
        return "row_count" if actual.count != original.count

        "value" if actual.ordered != original.ordered
      end

      # The candidate's verdict from the original's tiebreaker runs: they
      # match by ordered digest or group by group (tiebroken), or, when
      # CutTies.needed?, ResultComparison::CutTies' check runs on row
      # hashes, with this class as its source. Its runs
      # without a LIMIT keep only row hashes, and when one times out, the
      # comparison refuses with unsupported_order, as it did before the
      # check could recover a tie at a cut.
      class HashedRuns
        # A run without a LIMIT that's past FULL_RUN_ROW_CAP rows.
        class TooManyRows < StandardError; end

        # The most rows one of the cut-tie check's runs without a LIMIT may
        # hold hashes for (32 bytes each, plus Ruby's overhead). Four such
        # runs are held at once, so a result past it refuses, as a timeout
        # does, with unsupported_order. The rows still coming are discarded by
        # the ROLLBACK that ends the run.
        FULL_RUN_ROW_CAP = 2_000_000

        FULL_RUN_REASONS = { TimedOut => :full_run_timed_out, TooManyRows => :full_run_too_many_rows }.freeze

        def initialize(run, positions)
          @run = run
          @positions = positions
        end

        def verdict(shapes, originals)
          if ResultComparison::CutTies.unstable?(shapes.first, uncut: uncut?(originals))
            return ProductionComparison.refused("unstable_original")
          end
          return check(shapes, originals) if cut?(shapes.first, originals)

          verdict = tiebroken(shapes.last, originals)
          return verdict unless verdict.result == "pass" && cut?(shapes.last, originals)

          check(shapes, originals)
        end

        def fetch(shape, limited:)
          [false, true].map do |descending|
            sql = shape.with_tiebreaker(@positions, descending:, limited:)
            @run.digest(sql, nil, max_rows: (FULL_RUN_ROW_CAP unless limited)).hashes
          rescue TimedOut, TooManyRows => e
            raise if limited

            throw :full_timed_out, [:unsupported_order, { reason: FULL_RUN_REASONS.fetch(e.class) }]
          end
        end

        def key(row) = row
        def contained?(big, small) = ResultComparison::CutTies.tallied?(big, small)

        # Regrouped's source, for the candidate's runs: run(descending),
        # mismatch, and rows.
        def run(descending) = @run.digest(@candidate.with_tiebreaker(@positions, descending:))
        def mismatch(original, actual) = ProductionComparison.ordered_rule(original, actual)
        def rows(digested) = digested.hashes

        private

        # The candidate's verdict from its T and T' runs: by ordered digest,
        # or, when that fails, by row hashes (ResultComparison::Regrouped).
        def tiebroken(shape, originals)
          @candidate = shape
          found = ResultComparison::Regrouped.tiebroken(originals, self)
          case found
          when :match then ProductionComparison.pass
          when :unsupported_order then ProductionComparison.refused("unsteady_order")
          else ProductionComparison.fail(found.to_s)
          end
        end

        def check(shapes, originals)
          # ProductionComparison.positions gives a cut query every column, so
          # CutTies' tiebreaker covers them all.
          rule, fields = catch(:full_timed_out) do
            ResultComparison::CutTies.check(shapes, originals.map(&:hashes), self)
          end
          return ProductionComparison.pass unless rule
          return ProductionComparison.refused(fields[:reason].to_s) if rule == :unsupported_order

          ProductionComparison.fail(rule.to_s)
        end

        # Whether shape's LIMIT or OFFSET may cut a tie group, judged by the
        # original's tiebreaker runs. Called for the original's shape first,
        # then for a candidate's once it has matched those runs (tiebroken).
        def cut?(shape, originals)
          ResultComparison::CutTies.needed?(shape, uncut: uncut?(originals), kept_rows: originals.first.hashes.any?) do
            [false, true].map { @run.digest(shape.through_window(@positions, descending: it)).sorted }.uniq.one?
          end
        end

        # Whether the original's T and T' runs hold the same rows, by
        # sorted digest.
        def uncut?(originals) = originals.map(&:sorted).uniq.one?
      end

      # Runs queries for one compare.
      class Run
        attr_reader :connection

        def initialize(connection, params, timeout_ms, shifted: false)
          @connection = connection
          @params = params
          @timeout_ms = Integer(timeout_ms)
          @shifted = shifted
          @floats = false
        end

        # Whether any result this run streamed had a float column.
        def floats? = @floats

        # Streams sql's rows into a Digested. Yields each row's hash.
        # tie_positions, 1-based, turn on the hidden check.
        def digest(sql, tie_positions = nil, max_rows: nil, &)
          RunDiscipline::LOCK.synchronize do
            @connection.exec("BEGIN READ ONLY")
            begin
              started = ServerClock.mark(@connection, "SET LOCAL statement_timeout = #{@timeout_ms};")
              stream(sql, tie_positions, started, max_rows, &)
            ensure
              @connection.exec("ROLLBACK")
            end
          end
        end

        private

        # A cancel is a timeout only if timeout_ms has passed since started
        # on the server's clock, the one statement_timeout fires by. The
        # jump server's clock can run at another rate.
        def stream(sql, tie_positions, started, max_rows, &)
          rows = Rows.new(tie_positions, max_rows, shifted: @shifted)
          @connection.send_query_params(sql, @params)
          @connection.set_single_row_mode
          read(rows, &)
          rows.digested.tap { @floats ||= it.types.to_a.intersect?(ResultComparator::FLOAT_TYPES) }
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

      # The row key compare's second look uses: float columns cut, not
      # rounded, to eight significant digits, so the grid's boundaries sit
      # half a step from those of ResultComparator::Values's %.7e rounding,
      # and every other column as ResultComparator::Values keys it.
      module FloatNoise
        module_function

        def key(types, row)
          types.each_index.map do |i|
            value = row[i]
            next ResultComparator::Values.value_key(types[i], value) unless value && float?(types[i])

            "f:#{shifted(ResultComparator::Values.parse_float(value))}"
          end
        end

        def float?(type) = ResultComparator::FLOAT_TYPES.include?(type)

        # %.20e prints the double's own digits far past the eighth, so
        # cutting there floors its magnitude to eight significant digits.
        def shifted(value)
          return value.to_s if value.nan? || value.infinite?
          return "0" if value.abs < ResultComparator::ABSOLUTE_TOLERANCE

          digits, exponent = format("%.20e", value.abs).split("e")
          "#{"-" if value.negative?}#{digits[0, 9]}e#{exponent}"
        end
      end

      # Row hashes gathered from one query.
      class Rows
        def initialize(tie_positions, max_rows = nil, shifted: false)
          @kept = tie_positions&.map(&:pred)
          @max_rows = max_rows
          @shifted = shifted
          @hashes = []
          @ties = {}
          @hidden = false
        end

        def add(result)
          @types ||= result.nfields.times.map { result.ftype(it) }
          result.each_row do |row|
            key = row_key(row)
            hash = Digest::SHA256.digest(JSON.generate(key))
            @hashes << hash
            raise HashedRuns::TooManyRows if @max_rows && @hashes.size > @max_rows

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

        def row_key(row) = @shifted ? FloatNoise.key(@types, row) : ResultComparator::Values.key(@types, row)

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
