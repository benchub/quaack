# frozen_string_literal: true

module Quaack
  module Enclave
    # One column's row from pg_stats. correlation can be nil, because pg_stats
    # leaves it null for types without a sort order.
    #
    # most_common_vals and most_common_freqs are optional, and come together
    # or not at all: nil for both when pg_stats has no MCV list. The values
    # are Strings in the text form pg_stats prints them in (PgArray.parse
    # reads most_common_vals::text). The frequencies are finite Floats in
    # 0..1, one per value, that sum to at most 1 (plus FREQUENCY_SUM_SLACK).
    # They're fractions of all the rows, nulls included, as in pg_stats.
    #
    # MCV values are real data, value-class under the README's trust
    # boundary. So inspect, to_s, and pp show only how many there are
    # (most_common_vals=<3 redacted>), and no error message includes one.
    # Pattern matching can't see them at all: deconstruct_keys leaves them
    # out and there's no deconstruct, so a failed match can't quote them.
    # Only the most_common_vals reader and to_h give them back, and they
    # return the raw values, so keep what they return inside the enclave. The
    # frequencies are derived scalars and show everywhere.
    ColumnStatistics = Data.define(:n_distinct, :null_frac, :correlation, :most_common_vals, :most_common_freqs) do
      def initialize(n_distinct:, null_frac:, correlation:, most_common_vals: nil, most_common_freqs: nil)
        most_common_vals, most_common_freqs = most_common(most_common_vals, most_common_freqs)
        super(n_distinct: in_range(:n_distinct, n_distinct, -1..),
              null_frac: in_range(:null_frac, null_frac, 0..1),
              correlation: correlation && in_range(:correlation, correlation, -1..1),
              most_common_vals:, most_common_freqs:)
      end

      # The frequency of literal_text if it's one of the MCVs, compared by
      # exact text. Otherwise nil. TableStatistics#value_frequency covers the
      # values that aren't MCVs.
      def mcv_frequency(literal_text)
        index = most_common_vals&.index(boolean_text(literal_text))
        most_common_freqs[index] if index
      end

      # Pattern matching sees every member but the MCV values, so a failed
      # match can't quote them. There's no positional (array) pattern.
      def deconstruct_keys(keys) = super.except(:most_common_vals)

      undef_method :deconstruct

      # Like Data's own inspect, but with the MCV values replaced by a count.
      def inspect
        shown = to_h.map do |member, value|
          "#{member}=#{member == :most_common_vals && value ? "<#{value.size} redacted>" : value.inspect}"
        end
        "#<data #{self.class} #{shown.join(", ")}>"
      end

      alias_method :to_s, :inspect

      def pretty_print(pp) = pp.text(inspect)

      private

      # When every MCV is t or f, the column is almost surely boolean, so a
      # literal in one of boolin's full spellings reads as t or f.
      def boolean_text(literal_text)
        return literal_text unless most_common_vals.all? { |v| %w[t f].include?(v) }

        ColumnStatistics::BOOLEAN_SPELLINGS.fetch(literal_text.strip.downcase, literal_text)
      end

      def most_common(vals, freqs)
        return [nil, nil] if vals.nil? && freqs.nil?

        check_most_common(vals, freqs)
        freqs = freqs.map { |f| frequency(f) }.freeze
        too_much = freqs.sum > 1 + ColumnStatistics::FREQUENCY_SUM_SLACK
        raise ArgumentError, "most_common_freqs sum to more than 1" if too_much

        [vals.map { |v| v.dup.freeze }.freeze, freqs]
      end

      # No message names a value, only counts.
      def check_most_common(vals, freqs)
        problem = if vals.nil? || freqs.nil? then "most_common_vals and most_common_freqs must be given together"
                  elsif !strings?(vals) then "most_common_vals must be an Array of Strings"
                  elsif !freqs.is_a?(Array) then "most_common_freqs must be an Array"
                  elsif vals.size != freqs.size
                    "most_common_vals has #{vals.size} values but #{freqs.size} frequencies"
                  end
        raise ArgumentError, problem if problem
      end

      def strings?(vals) = vals.is_a?(Array) && vals.all?(String)

      # Unlike in_range, the message leaves the value out, in case an MCV
      # value was passed as a frequency by mistake.
      def frequency(value)
        number = Float(value) if value.is_a?(Numeric) && value.real?
        return number if number && (0..1).cover?(number) # NaN and Infinity aren't in 0..1

        raise ArgumentError, "most_common_freqs must hold finite numbers in 0..1"
      end

      def in_range(what, value, range)
        number = Float(value) if value.is_a?(Numeric) && value.real?
        return number if number&.finite? && range.cover?(number)

        raise ArgumentError, "#{what} must be a finite number in #{range}, got #{value.inspect}"
      end
    end

    # How far over 1 the frequencies may sum. pg_stats stores them as float4,
    # so a list that covers every row can come out a hair over.
    ColumnStatistics::FREQUENCY_SUM_SLACK = 1e-6

    # The spellings Postgres's boolin reads, ignoring case and surrounding
    # whitespace, and the text pg_stats prints for each. boolin also takes
    # unique prefixes, such as tr or of. Those aren't here, so they miss.
    ColumnStatistics::BOOLEAN_SPELLINGS = {
      "true" => "t", "t" => "t", "yes" => "t", "y" => "t", "on" => "t", "1" => "t",
      "false" => "f", "f" => "f", "no" => "f", "n" => "f", "off" => "f", "0" => "f"
    }.freeze
  end
end
