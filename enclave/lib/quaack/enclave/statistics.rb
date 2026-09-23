# frozen_string_literal: true

require_relative "table_name"

module Quaack
  module Enclave
    # The statistics input: what the index generators (README 5a-1 and 5a-2)
    # read about each table and column. It holds only derived scalars, which
    # are shape-class data under the README's trust boundary. It never holds
    # most_common_vals or histogram_bounds.
    #
    #   stats = Statistics.new(tables: [
    #     TableStatistics.new(name: TableName.new(schema: "public", name: "orders"),
    #                         reltuples: 1_000_000.0,
    #                         columns: { "status" => ColumnStatistics.new(n_distinct: 5.0, null_frac: 0.0,
    #                                                                     correlation: nil) })
    #   ])
    #   stats.table(orders_name).distinct_count("status")   # => 5.0
    #
    # Missing lookups raise KeyError. Use table? and column? to check first.

    # One column's row from pg_stats. correlation can be nil, because pg_stats
    # leaves it null for types without a sort order.
    ColumnStatistics = Data.define(:n_distinct, :null_frac, :correlation) do
      def initialize(n_distinct:, null_frac:, correlation:)
        self.class.check_range(:n_distinct, n_distinct, -1..)
        self.class.check_range(:null_frac, null_frac, 0..1)
        self.class.check_range(:correlation, correlation, -1..1) unless correlation.nil?
        super
      end

      def self.check_range(what, value, range)
        return if value.is_a?(Numeric) && range.cover?(value)

        raise ArgumentError, "#{what} must be a number in #{range}, got #{value.inspect}"
      end
    end

    # One table: its name, pg_class.reltuples, and its columns by name.
    # A negative reltuples means the table has never been analyzed.
    TableStatistics = Data.define(:name, :reltuples, :columns) do
      def initialize(name:, reltuples:, columns:)
        raise ArgumentError, "name must be a TableName" unless name.is_a?(TableName)
        raise ArgumentError, "reltuples must be a number, got #{reltuples.inspect}" unless reltuples.is_a?(Numeric)

        super(name:, reltuples:, columns: self.class.column_map(columns))
      end

      def self.column_map(columns)
        valid = columns.is_a?(Hash) && columns.all? { |k, v| k.is_a?(String) && v.is_a?(ColumnStatistics) }
        raise ArgumentError, "columns must map column names to ColumnStatistics" unless valid

        columns.to_h { |k, v| [k.dup.freeze, v] }.freeze
      end

      # Raises KeyError if the table has no statistics for the column.
      def column(column_name)
        columns.fetch(column_name) { raise KeyError, "table #{name} has no statistics for column #{column_name}" }
      end

      def column?(column_name) = columns.key?(column_name)

      # The estimated number of distinct non-null values in the column.
      # A positive n_distinct is the count itself. A negative one is a
      # fraction of the row count, so the count is abs(n_distinct) * reltuples.
      # Returns nil when the count is unknown: n_distinct is 0, or it's
      # negative and reltuples is negative (never analyzed).
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
      # selective. This is the "discount by null_frac" from README 5a-1 step 2.
      # It's applied to the selectivity, not to the distinct count, because
      # n_distinct already counts only non-null values. Returns nil when the
      # distinct count is unknown. It ignores MCV frequencies.
      def equality_selectivity(column_name)
        count = distinct_count(column_name)
        return nil if count.nil?

        (1 - column(column_name).null_frac) / count
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
