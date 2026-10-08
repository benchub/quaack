# frozen_string_literal: true

require_relative "table_name"
require_relative "index_candidate"
require_relative "column_statistics"

module Quaack
  module Enclave
    # The statistics input: what the index generators (DESIGN.md's index-from-query and index-from-plan)
    # and the filter (index-dedupe) read about each table. It holds names, derived
    # scalars, existing index definitions, and each column's MCV list. It
    # never holds histogram_bounds. Two parts of it are value-class data: the
    # MCV values (see ColumnStatistics) and the partial-index predicates in
    # the existing indexes (see IndexCandidate). inspect, to_s, pp, and error
    # messages redact both, up through TableStatistics and Statistics, whose
    # inspect and pp are built from their parts'.
    #
    # Later tasks fill it in: the column list and existing indexes come from
    # the schema dump (DESIGN.md's schema-dump), and the numbers and MCV lists from
    # pg_stats and pg_class (statistics).
    #
    #   orders = TableName.new(schema: "public", name: "orders")
    #   stats = Statistics.new(tables: [
    #     TableStatistics.new(
    #       name: orders,
    #       reltuples: 1_000_000,
    #       column_names: %w[id status note],     # every column, in attnum order
    #       columns: { "status" => ColumnStatistics.new(n_distinct: 5, null_frac: 0, correlation: nil,
    #                                                   most_common_vals: %w[delivered shipped],  # optional
    #                                                   most_common_freqs: [0.7, 0.2]) },         # optional
    #       indexes: { "orders_pkey" => IndexCandidate.from_indexdef(pkey_indexdef),
    #                  "orders_note_trgm_idx" => nil }  # nil: from_indexdef couldn't represent it
    #     )
    #   ])
    #   stats.table(orders).distinct_count("status")              # => 5.0
    #   stats.table(orders).value_frequency("status", "shipped")  # => 0.2, its MCV frequency
    #   stats.table(orders).value_frequency("status", "pending")  # => 0.0333..., (1 - 0.9) / (5 - 2)
    #
    # Numbers are stored as finite Floats. Missing lookups raise KeyError. Use
    # table? and column? to check first.

    # One table: its name, pg_class.reltuples, every column's name in attnum
    # order, the pg_stats row for each column that has one, and the existing
    # indexes by name. No column name can appear twice. An index maps to nil
    # when IndexCandidate.from_indexdef couldn't represent it. Primary keys and
    # other unique indexes are candidates with unique: true. A negative
    # reltuples means the table has never been analyzed.
    TableStatistics = Data.define(:name, :reltuples, :columns, :column_names, :indexes) do
      def initialize(name:, reltuples:, columns:, column_names:, indexes:)
        raise ArgumentError, "name must be a TableName" unless name.is_a?(TableName)

        column_names = names_of(column_names)
        super(name:, reltuples: finite(reltuples), columns: column_map(columns, column_names),
              column_names:, indexes: index_map(indexes, name))
      end

      # Raises KeyError if the table has no statistics for the column.
      def column(column_name)
        columns.fetch(column_name) { raise KeyError, "table #{name} has no statistics for column #{column_name}" }
      end

      def column?(column_name) = columns.key?(column_name)

      # The estimated number of distinct non-null values in the column.
      # A positive n_distinct is the count itself. A negative one is a
      # fraction of all the rows, nulls included, so the count is
      # abs(n_distinct) * reltuples. That's 0.0 for an empty table. Returns
      # nil when the count is unknown: n_distinct is 0, or it's negative and
      # reltuples is negative (never analyzed).
      def distinct_count(column_name)
        n_distinct = column(column_name).n_distinct
        if n_distinct.positive?
          n_distinct
        elsif n_distinct.negative? && !reltuples.negative?
          n_distinct.abs * reltuples
        end
      end

      # The estimated fraction of the table's rows that match `column = v` for
      # a typical v: (1 - null_frac) / distinct_count. Smaller is more
      # selective. This is the "discount by null_frac" from DESIGN.md's index-from-query inventory.
      # It's applied to the selectivity, not to the distinct count, because
      # the distinct count already leaves out nulls. It matches Postgres's
      # estimate for a value that isn't an MCV when there's no MCV list, and
      # ignores MCV frequencies. value_frequency uses them.
      # Returns nil when the distinct count is unknown or zero.
      def equality_selectivity(column_name)
        count = distinct_count(column_name)
        return nil if count.nil? || count.zero?

        (1 - column(column_name).null_frac) / count
      end

      # The estimated fraction of the table's rows that match
      # `column = literal`, the way Postgres's var_eq_const (selfuncs.c)
      # estimates it. index-from-plan uses it to tell whether a constant predicate
      # removes most rows on its own. literal_text is the literal in the text
      # form pg_stats prints the column's values in.
      #
      # - If literal_text is an MCV, it's that MCV's frequency.
      # - Otherwise the rows the MCVs and nulls don't cover,
      #   max(0, 1 - sum(most_common_freqs) - null_frac), are split evenly
      #   among the other distinct values: divided by distinct_count minus
      #   the number of MCVs, but only when that's more than 1, as Postgres
      #   does. So when every distinct value is an MCV, there's no division
      #   by zero or a negative: the leftover fraction, often 0.0, stands.
      #   Then, as in Postgres, the result is capped at the least common
      #   MCV's frequency. A column with no MCV list gets
      #   (1 - null_frac) / distinct_count.
      #
      # Returns nil when the column is in column_names but has no pg_stats
      # row, and for a literal that isn't an MCV when the distinct count is
      # unknown or zero. Raises KeyError for a column that isn't in
      # column_names at all.
      #
      # The MCV match compares text, not values under the column type's
      # equality operator, which is what Postgres uses. So it misses a
      # literal spelled differently from how pg_stats prints the value:
      # 1.5 for a numeric MCV printed as 1.50, 'ABC' for a citext MCV 'abc',
      # 'ab' for a char(n) MCV printed with its padding as "ab  ", a date or
      # timestamp written in another format, DateStyle, or time zone, a
      # float printed with different digits, or a boolean in a prefix
      # spelling like 'tr' (the full spellings do match; see
      # ColumnStatistics#mcv_frequency). A missed match falls through to the
      # estimate for values that aren't MCVs, which is usually far too low.
      # When the MCVs cover the whole column, as they often do for status and
      # type columns, it comes out 0.0: "selects almost nothing", for what
      # may be the column's most common value.
      #
      # Postgres also does things this doesn't:
      # - It uses 1 / reltuples for a column with a unique index.
      # - It rounds the distinct count to a whole number, at least 1.
      # - It falls back to a default distinct count (200, or reltuples for a
      #   small table) where this returns nil.
      # - It uses the planner's current row estimate, not reltuples.
      # The row count EXPLAIN shows is this times the rows, rounded, and at
      # least 1, with one exception: Postgres rewrites bool_col = false as
      # NOT bool_col and estimates it as 1 - freq(t), which counts NULL rows
      # as matching. This follows var_eq_const instead and returns freq(f),
      # the fraction that really matches, so on a nullable boolean it is
      # lower than EXPLAIN's estimate for = false.
      def value_frequency(column_name, literal_text)
        raise ArgumentError, "literal_text must be a String" unless literal_text.is_a?(String)
        return nil if !column?(column_name) && column_names.include?(column_name)

        stats = column(column_name)
        stats.mcv_frequency(literal_text) || other_value_frequency(stats, distinct_count(column_name))
      end

      private

      def other_value_frequency(stats, count)
        return nil if count.nil? || count.zero?

        freqs = stats.most_common_freqs || []
        frequency = [1 - freqs.sum - stats.null_frac, 0.0].max
        others = count - freqs.size
        frequency /= others if others > 1
        [frequency, *freqs.min].min
      end

      def finite(reltuples)
        number = Float(reltuples) if reltuples.is_a?(Numeric) && reltuples.real?
        return number if number&.finite?

        raise ArgumentError, "reltuples must be a finite number"
      end

      def names_of(column_names)
        valid = column_names.is_a?(Array) && column_names.all? { |c| c.is_a?(String) && !c.empty? }
        raise ArgumentError, "column_names must be an Array of non-empty Strings" unless valid

        check_no_repeats(column_names)
        column_names.map { |c| c.dup.freeze }.freeze
      end

      def check_no_repeats(column_names)
        twice = column_names.tally.select { |_, count| count > 1 }.keys
        raise ArgumentError, "column_names lists a name twice: #{twice.join(", ")}" if twice.any?
      end

      def column_map(columns, column_names)
        valid = columns.is_a?(Hash) && columns.all? { |k, v| k.is_a?(String) && v.is_a?(ColumnStatistics) }
        raise ArgumentError, "columns must map column names to ColumnStatistics" unless valid

        unknown = columns.keys - column_names
        raise ArgumentError, "statistics for columns not in column_names: #{unknown.join(", ")}" if unknown.any?

        columns.dup.freeze
      end

      def index_map(indexes, table)
        raise ArgumentError, "indexes must be a Hash" unless indexes.is_a?(Hash)

        indexes.each { |index_name, candidate| check_index(index_name, candidate, table) }
        indexes.dup.freeze
      end

      def check_index(index_name, candidate, table)
        named = index_name.is_a?(String) && !index_name.empty?
        raise ArgumentError, "index name must be a non-empty String" unless named
        return if candidate.nil?

        problem = if !candidate.is_a?(IndexCandidate) then "must be an IndexCandidate or nil"
                  elsif candidate.table != table then "is on #{candidate.table}, not #{table}"
                  end
        raise ArgumentError, "index #{index_name} #{problem}" if problem
      end
    end

    # Every table's statistics, looked up by TableName.
    Statistics = Data.define(:tables) do
      def initialize(tables:)
        by_name = {}
        tables.each do |table|
          raise ArgumentError, "tables must be TableStatistics" unless table.is_a?(TableStatistics)
          raise ArgumentError, "two entries for table #{table.name}" if by_name.key?(table.name)

          by_name[table.name] = table
        end
        super(tables: by_name.freeze)
      end

      # Raises KeyError if there are no statistics for the table.
      def table(table_name)
        tables.fetch(table_name) { raise KeyError, "no statistics for table #{table_name}" }
      end

      def table?(table_name) = tables.key?(table_name)
    end
  end
end
