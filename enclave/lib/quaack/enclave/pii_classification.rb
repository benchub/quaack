# frozen_string_literal: true

require_relative "table_name"
require_relative "planner_statistics"

module Quaack
  module Enclave
    # README 3f: classify every column of the query's tables as PII or not,
    # mark the low-cardinality ones, and work out which of their statistics
    # may leave the enclave. It reads the statistics entry 3c stored
    # (PlannerStatistics.run) and the quaacks Config, and stores its own
    # entry. It sends nothing itself: a later step hands outbound_statistics
    # to egress.
    #
    #   result = PiiClassification.run(store:, config: Config.load)
    #   result.columns              # => [Column(table: public.users, name: "email", pii: true,
    #                               #            low_cardinality: false), ...]
    #   result.low_cardinality      # => [[TableName(public.users), "status"]], Dedupe's low_cardinality
    #   result.outbound_statistics  # => { "tables" => [...] }, what may leave, as plain JSON data
    #   PiiClassification.load(store) # => the same Result, rebuilt from the store
    #
    # The threshold is config.cardinality_threshold, 50 unless the config
    # changes it. A column's distinct count is TableStatistics#distinct_count,
    # as 5a-1 counts it. It's unknown when the column has no pg_stats row
    # (never analyzed), or when n_distinct is 0.
    #
    # - A column is PII when a config.pii_columns glob matches it, or when
    #   it's text-like (PlannerStatistics's text_columns: text, varchar,
    #   char, name, citext, or a domain over one) and its distinct count is
    #   the threshold or more, or unknown. Unknown text fails closed.
    # - A column is low-cardinality when it isn't PII, its distinct count is
    #   known and under the threshold, and its pg_stats n_distinct is
    #   positive. ANALYZE stores a positive count only when the distinct
    #   values are at most about a tenth of the rows, so each one repeats.
    #   A negative n_distinct means the values mostly don't repeat, as in a
    #   small table of emails, so they aren't categories and never leave.
    #   This is the set Dedupe takes.
    #
    # outbound_statistics is a pure projection of the stored statistics:
    # for each table, in order, its schema and name, and for each column in
    # attnum order, a Hash with exactly these keys:
    # - name.
    # - n_distinct, null_frac, and correlation, for every column, PII or
    #   not. nil when the column has no pg_stats row (or no correlation).
    # - most_common_freqs, only for a column that isn't PII. Otherwise nil.
    # - most_common_vals, only for a low-cardinality column. Otherwise nil.
    # Histogram bounds, avg_width, indexes, extended statistics, and
    # reltuples never go in. The MCV values of a low-cardinality column are
    # the only real values it holds, and README 3f lets those leave.
    #
    # The stored entry, classification, holds "columns" (schema, table,
    # column, pii, and low_cardinality for each column) and
    # "outbound_statistics".
    module PiiClassification
      # One column's classification. table is a TableName.
      Column = Data.define(:table, :name, :pii, :low_cardinality)
      Result = Data.define(:columns, :low_cardinality, :outbound_statistics)

      ENTRY = "classification"

      module_function

      def run(store:, config:)
        data = store.read(PlannerStatistics::ENTRY)
        statistics = PlannerStatistics.build(data).statistics
        columns = data["tables"].flat_map { classify_table(it, statistics, config) }
        store.write(ENTRY, { "columns" => columns, "outbound_statistics" => outbound(data, columns) })
        load(store)
      end

      def load(store) = build(store.read(ENTRY))

      def build(entry)
        columns = entry["columns"].map do |row|
          Column.new(table: TableName.new(schema: row["schema"], name: row["table"]), name: row["column"],
                     pii: row["pii"], low_cardinality: row["low_cardinality"])
        end
        Result.new(columns:, low_cardinality: columns.select(&:low_cardinality).map { [it.table, it.name] },
                   outbound_statistics: entry["outbound_statistics"])
      end

      def classify_table(table, statistics, config)
        name = TableName.new(schema: table["schema"], name: table["name"])
        stats = statistics.table(name)
        table["column_names"].map do |column|
          count = stats.column?(column) ? stats.distinct_count(column) : nil
          pii, low = classes(config, name, column, table["text_columns"].include?(column), count)
          low &&= stats.column(column).n_distinct.positive?
          { "schema" => name.schema, "table" => name.name, "column" => column, "pii" => pii, "low_cardinality" => low }
        end
      end

      # [pii, low_cardinality] for one column. count is its distinct count,
      # or nil when that's unknown.
      def classes(config, table, column, text, count)
        threshold = config.cardinality_threshold
        pii = config.pii_column?(table, column) || (text && (count.nil? || count >= threshold))
        [pii, !pii && !count.nil? && count < threshold]
      end

      def outbound(data, columns)
        classes = columns.to_h { [[it["schema"], it["table"], it["column"]], it] }
        { "tables" => data["tables"].map do |table|
          { "schema" => table["schema"], "name" => table["name"],
            "columns" => table["column_names"].map do |column|
              outbound_column(column, table["columns"][column] || {},
                              classes.fetch([table["schema"], table["name"], column]))
            end }
        end }
      end

      def outbound_column(column, row, classified)
        { "name" => column, "n_distinct" => row["n_distinct"], "null_frac" => row["null_frac"],
          "correlation" => row["correlation"],
          "most_common_freqs" => (row["most_common_freqs"] unless classified["pii"]),
          "most_common_vals" => (row["most_common_vals"] if classified["low_cardinality"]) }
      end
    end
  end
end
