# frozen_string_literal: true

require_relative "arena_fixture"

module Quaack
  module Enclave
    # Step 9d's comparator, reused by 10b and 14c: says whether a candidate's
    # result matches the original's. This part is pure. It takes two
    # ArenaRunner::Results and a mode, and runs nothing. ResultComparison
    # (result_comparison.rb) picks the mode from the original query and
    # builds the queries to run.
    #
    # Modes:
    #
    # - multiset: the same rows, in any order, with the same multiplicities.
    # - ordered: the same rows in the same order.
    # - subset: LIMIT or OFFSET with no ORDER BY. expected is the original's
    #   full result, run without them. The candidate's rows must be a
    #   sub-multiset of it, with exactly expected_count rows.
    #
    # A Verdict can also name with_ties, the mode for FETCH FIRST ... WITH
    # TIES, which compare doesn't take. ResultComparison refuses it (see
    # there).
    #
    # Columns. The counts and then the type OIDs must be equal, column by
    # column, before any value is compared. int4 against int8 is a
    # column_types mismatch: step 8 already discards a candidate whose
    # output types differ. Column names are ignored.
    #
    # Values are Postgres text output, with nil for NULL, and NULL equals
    # NULL. By column type:
    #
    # - float4 and float8: equal within a relative 1e-9, or an absolute 1e-12
    #   near zero. NaN equals NaN, each infinity equals only itself, and -0
    #   equals 0.
    # - numeric: equal by value, exactly, so 1.0 equals 1.00. NaN and the
    #   infinities equal only themselves.
    # - Everything else: exact text. That includes arrays and composites
    #   that hold floats or numerics, so float noise inside one, or a
    #   numeric's printed scale, is a mismatch. That limitation can only
    #   discard a good candidate, never pass a bad one.
    #
    # Tolerance and multisets. Tolerance isn't transitive, so rows can't be
    # grouped by equality. Instead, each expected row goes in a bucket by a
    # key that rounds floats (to eight significant digits, and to zero below
    # 1e-12) and is exact for every other type. Each candidate row, in order,
    # takes the first row left in its bucket that it equals within
    # tolerance. A match is claimed only when every candidate row found its
    # own partner this way, so a match is always real. The edge case goes
    # the other way: two floats within tolerance of each other but on
    # either side of a rounding boundary land in different buckets, and
    # the comparison says mismatch. So does a greedy pick in a bucket that
    # leaves a later row without the one partner it had. With no float
    # columns the key is exact, and neither can happen.
    #
    # Trust boundary. A Verdict holds only a boolean, symbols, counts, and
    # positions, never a row value, and it checks that on creation. Errors
    # here carry fixed messages.
    module ResultComparator
      MODES = %i[multiset ordered subset].freeze
      VERDICT_MODES = [*MODES, :with_ties].freeze

      # What decided a mismatch:
      # - column_count, column_types: the result shapes differ. column is
      #   the first differing column's index for column_types.
      # - row_count: the candidate has the wrong number of rows.
      # - value (ordered): the first row and column that differ.
      # - multiset, subset: row is the first candidate row, by its index in
      #   the candidate's result, with no partner.
      # - candidate_unordered: the original has an ORDER BY and the
      #   candidate has none. ResultComparison decides this one.
      # - unsupported_order: the original's order is one the comparison
      #   can't check, so it never says match. ResultComparison decides
      #   this one too.
      RULES = %i[column_count column_types row_count value multiset subset candidate_unordered
                 unsupported_order].freeze

      FLOAT_TYPES = [700, 701].freeze
      NUMERIC_TYPE = 1700
      RELATIVE_TOLERANCE = 1e-9
      ABSOLUTE_TOLERANCE = 1e-12

      # match is true or false. rule is nil for a match. expected_rows and
      # actual_rows are counts, nil when nothing was counted. For subset,
      # expected_rows is the expected count, not the full result's size. row
      # and column are zero-based positions, or nil.
      Verdict = Data.define(:match, :mode, :rule, :expected_rows, :actual_rows, :row, :column) do
        def initialize(**fields)
          problem, = VERDICT_CHECKS.find { |_, ok| !ok.call(fields) }
          raise ArgumentError, problem if problem

          super
        end

        def match? = match

        # A verdict from a mode and a mismatch rule, or no rule for a match.
        # counts and positions are expected_rows, actual_rows, row, and
        # column, each nil when not given.
        def self.for(mode, rule = nil, **counts_and_positions)
          new(match: rule.nil?, mode:, rule:, expected_rows: nil, actual_rows: nil, row: nil, column: nil,
              **counts_and_positions)
        end
      end

      # Each Verdict check in order, with the message for one that fails it.
      # The messages never name a value.
      VERDICT_CHECKS = {
        "a verdict's match must be true or false" => ->(f) { [true, false].include?(f[:match]) },
        "a verdict's mode must be one of VERDICT_MODES" => ->(f) { VERDICT_MODES.include?(f[:mode]) },
        "a verdict's rule must be one of RULES, or nil" => ->(f) { f[:rule].nil? || RULES.include?(f[:rule]) },
        "a verdict's counts and positions must be non-negative Integers or nil" => lambda do |f|
          f.values_at(:expected_rows, :actual_rows, :row, :column)
           .all? { |n| n.nil? || (n.is_a?(Integer) && !n.negative?) }
        end
      }.freeze

      module_function

      def compare(expected, actual, mode:, expected_count: nil)
        check_arguments(expected, actual, mode, expected_count)
        counts = { expected_rows: mode == :subset ? expected_count : expected.rows.size, actual_rows: actual.rows.size }
        shape_mismatch(expected, actual, mode, counts) ||
          row_count_mismatch(mode, counts) ||
          rows_mismatch(expected, actual, mode, counts) ||
          Verdict.for(mode, **counts)
      end

      def check_arguments(expected, actual, mode, expected_count)
        unless [expected, actual].all?(ArenaRunner::Result)
          raise ArgumentError, "compare takes two ArenaRunner::Results"
        end
        raise ArgumentError, "mode must be one of #{MODES.join(", ")}" unless MODES.include?(mode)
        return unless mode == :subset
        return if expected_count.is_a?(Integer) && !expected_count.negative?

        raise ArgumentError, "subset needs an expected_count, a non-negative Integer"
      end

      def shape_mismatch(expected, actual, mode, counts)
        return Verdict.for(mode, :column_count, **counts) if expected.types.size != actual.types.size

        column = expected.types.each_index.find { |i| expected.types[i] != actual.types[i] }
        Verdict.for(mode, :column_types, column:, **counts) if column
      end

      def row_count_mismatch(mode, counts)
        Verdict.for(mode, :row_count, **counts) if counts[:expected_rows] != counts[:actual_rows]
      end

      def rows_mismatch(expected, actual, mode, counts)
        types = expected.types
        return ordered_mismatch(types, expected.rows, actual.rows, counts) if mode == :ordered

        row = unpartnered_row(types, expected.rows, actual.rows)
        Verdict.for(mode, mode == :subset ? :subset : :multiset, row:, **counts) if row
      end

      def ordered_mismatch(types, expected_rows, actual_rows, counts)
        expected_rows.each_with_index do |expected_row, row|
          column = types.each_index.find { |i| !Values.equal?(types[i], expected_row[i], actual_rows[row][i]) }
          return Verdict.for(:ordered, :value, row:, column:, **counts) if column
        end
        nil
      end

      # The index of the first actual row with no partner of its own among
      # the expected rows, or nil when every one has one.
      def unpartnered_row(types, expected_rows, actual_rows)
        buckets = expected_rows.group_by { |row| Values.key(types, row) }
        actual_rows.each_with_index.find do |row, _|
          bucket = buckets.fetch(Values.key(types, row), [])
          partner = bucket.index { |candidate| Values.row_equal?(types, candidate, row) }
          partner.nil? || !bucket.delete_at(partner)
        end&.last
      end

      # Equality and bucket keys for single values, by column type.
      module Values
        module_function

        def row_equal?(types, left, right) = types.each_index.all? { |i| equal?(types[i], left[i], right[i]) }

        def equal?(type, left, right)
          return left.nil? && right.nil? if left.nil? || right.nil?
          return floats_equal?(parse_float(left), parse_float(right)) if FLOAT_TYPES.include?(type)
          return numeric_text(left) == numeric_text(right) if type == NUMERIC_TYPE

          left == right
        end

        def key(types, row) = types.each_index.map { |i| value_key(types[i], row[i]) }

        def value_key(type, value)
          return "null" if value.nil?
          return "f:#{float_key(parse_float(value))}" if FLOAT_TYPES.include?(type)
          return "n:#{numeric_text(value)}" if type == NUMERIC_TYPE

          "t:#{value}"
        end

        SPECIAL_FLOATS = { "NaN" => Float::NAN, "Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY }.freeze

        # A float's text output as a Float. Ruby's Float() doesn't read
        # Postgres's NaN or infinities, hence SPECIAL_FLOATS. Postgres always
        # prints a float that this reads, so other text means the Result
        # wasn't a real one, and it's refused.
        def parse_float(text)
          SPECIAL_FLOATS.fetch(text) do
            Float(text, exception: false) or raise ArgumentError, "a float column holds text that isn't a float"
          end
        end

        def floats_equal?(left, right)
          return left.nan? && right.nan? if left.nan? || right.nan?

          [left, right].all?(&:finite?) ? within_tolerance?(left, right) : left == right
        end

        # Relative to the larger magnitude, so the order of the two values
        # doesn't matter. The two differ at the edge: 7.603 against
        # 7.603000007603 is equal here, but wouldn't be relative to the
        # smaller.
        def within_tolerance?(left, right)
          (left - right).abs <= [RELATIVE_TOLERANCE * [left.abs, right.abs].max, ABSOLUTE_TOLERANCE].max
        end

        def float_key(value)
          return value.to_s if value.nan? || value.infinite?
          return "0" if value.abs < ABSOLUTE_TOLERANCE

          format("%.7e", value)
        end

        # numeric's text output with its scale's trailing zeros dropped, so
        # equal values give equal text. numeric_out never uses an exponent,
        # or a leading zero before another digit. Anything else, such as NaN
        # or Infinity, is kept as it is.
        def numeric_text(text)
          match = /\A(-?)(\d+)(?:\.(\d+))?\z/.match(text)
          return text unless match

          fraction = match[3].to_s.sub(/0+\z/, "")
          digits = fraction.empty? ? match[2] : "#{match[2]}.#{fraction}"
          digits == "0" ? "0" : "#{match[1]}#{digits}"
        end
      end
    end
  end
end
