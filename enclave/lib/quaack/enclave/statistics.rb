# frozen_string_literal: true

require_relative "table_name"
require_relative "index_candidate"

module Quaack
  module Enclave
    # The statistics input: what the index generators (README 5a-1 and 5a-2)
    # and the filter (5a-3) read about each table. It holds names, derived
    # scalars, and existing index definitions. It never holds
    # most_common_vals or histogram_bounds. The existing indexes can hold
    # partial-index predicates, which are value-class data (see
    # IndexCandidate).
    #
    # Later tasks fill it in: the column list and existing indexes come from
    # the schema dump (README 3b), and the numbers from pg_stats and pg_class
    # (3c).
    #
    #   orders = TableName.new(schema: "public", name: "orders")
    #   stats = Statistics.new(tables: [
    #     TableStatistics.new(
    #       name: orders,
    #       reltuples: 1_000_000,
    #       column_names: %w[id status note],     # every column, in attnum order
    #       columns: { "status" => ColumnStatistics.new(n_distinct: 5, null_frac: 0, correlation: nil) },
    #       indexes: { "orders_pkey" => nil,      # nil: from_ddl couldn't represent it
    #                  "orders_status_idx" => IndexCandidate.from_ddl(indexdef, sources: [:existing]) }
    #     )
    #   ])
    #   stats.table(orders).distinct_count("status")   # => 5.0
    #
    # Numbers are stored as finite Floats. Missing lookups raise KeyError. Use
    # table? and column? to check first.

    # One column's row from pg_stats. correlation can be nil, because pg_stats
    # leaves it null for types without a sort order.
    ColumnStatistics = Data.define(:n_distinct, :null_frac, :correlation) do
      def initialize(n_distinct:, null_frac:, correlation:)
        super(n_distinct: in_range(:n_distinct, n_distinct, -1..),
              null_frac: in_range(:null_frac, null_frac, 0..1),
              correlation: correlation && in_range(:correlation, correlation, -1..1))
      end

      private

      def in_range(what, value, range)
        number = Float(value) if value.is_a?(Numeric)
        return number if number&.finite? && range.cover?(number)

        raise ArgumentError, "#{what} must be a finite number in #{range}, got #{value.inspect}"
      end
    end

    # One table: its name, pg_class.reltuples, every column's name in attnum
    # order, the pg_stats row for each column that has one, and the existing
    # indexes by name. An index maps to nil when IndexCandidate.from_ddl
    # couldn't represent it. A negative reltuples means the table has never
    # been analyzed.
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
      # selective. This is the "discount by null_frac" from README 5a-1 step 2.
      # It's applied to the selectivity, not to the distinct count, because
      # the distinct count already leaves out nulls. It matches Postgres's
      # estimate for a value that isn't an MCV, and ignores MCV frequencies.
      # Returns nil when the distinct count is unknown or zero.
      def equality_selectivity(column_name)
        count = distinct_count(column_name)
        return nil if count.nil? || count.zero?

        (1 - column(column_name).null_frac) / count
      end

      private

      def finite(reltuples)
        number = Float(reltuples) if reltuples.is_a?(Numeric)
        return number if number&.finite?

        raise ArgumentError, "reltuples must be a finite number, got #{reltuples.inspect}"
      end

      def names_of(column_names)
        valid = column_names.is_a?(Array) && column_names.all? { |c| c.is_a?(String) && !c.empty? }
        raise ArgumentError, "column_names must be an Array of non-empty Strings" unless valid

        column_names.map { |c| c.dup.freeze }.freeze
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
