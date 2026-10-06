# frozen_string_literal: true

require "pg_query"
require_relative "table_name"
require_relative "planner_statistics"

module Quaack
  module Enclave
    # DESIGN.md's classify: classify every column of the query's tables as PII or not,
    # mark the low-cardinality ones, and work out which of their statistics
    # may leave the enclave. It reads the statistics entry statistics stored
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
    # as index-from-query counts it. It's unknown when the column has no pg_stats row
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
    #   A structured column (PlannerStatistics's structured_columns: json,
    #   jsonb, xml, tsvector, tsquery, hstore, a composite type, a range, a
    #   multirange, an array, or a domain over one) is never
    #   low-cardinality, however few values it holds: a document, list,
    #   record, or span can hold facts about a person, so its values never
    #   leave. Its frequencies follow
    #   the rules above.
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
    # Each table also gets:
    # - indexes: for each index, its name, definition, and columns, its
    #   expressions' pg_stats rows in the same form as a column's.
    # - extended_statistics: for each CREATE STATISTICS object, its schema,
    #   name, definition, kinds, n_distinct, and dependencies, and its
    #   most_common_vals, most_common_val_nulls, most_common_freqs, and
    #   most_common_base_freqs, nil as below.
    # Both are classified by their base columns: every column the
    # definition names (key, expression, or index predicate), found with
    # pg_query. One that names any PII column, or a column the table
    # doesn't have, or whose definition won't parse, is PII: none of its
    # MCV data goes in. Otherwise its frequencies go in, and its values go
    # in only when every base column is low-cardinality. An index's
    # expressions are classified together, by all its base columns.
    # Histogram bounds, avg_width, and reltuples never go in. The MCV values of a low-cardinality column are
    # the only real values it holds, and DESIGN.md's classify lets those leave.
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
        structured = table.fetch("structured_columns")
        table["column_names"].map do |column|
          pii, low = classes(config, stats, column, table["text_columns"].include?(column))
          low &&= !structured.include?(column)
          { "schema" => name.schema, "table" => name.name, "column" => column, "pii" => pii, "low_cardinality" => low }
        end
      end

      # [pii, low_cardinality] for one column of stats, a TableStatistics,
      # before the structured rule. count is its distinct count, or nil when
      # that's unknown.
      def classes(config, stats, column, text)
        count = stats.column?(column) ? stats.distinct_count(column) : nil
        threshold = config.cardinality_threshold
        pii = config.pii_column?(stats.name, column) || (text && (count.nil? || count >= threshold))
        [pii, !pii && repeats?(stats, column) && count < threshold]
      end

      # Whether pg_stats has a positive n_distinct for the column, so its
      # distinct count is known and each value repeats.
      def repeats?(stats, column) = stats.column?(column) && stats.column(column).n_distinct.positive?

      def outbound(data, columns)
        classes = columns.to_h { [[it["schema"], it["table"], it["column"]], it] }
        { "tables" => data["tables"].map { outbound_table(it, classes) } }
      end

      def outbound_table(table, classes)
        { "schema" => table["schema"], "name" => table["name"],
          "columns" => table["column_names"].map do |column|
            outbound_column(column, table["columns"][column] || {},
                            classes.fetch([table["schema"], table["name"], column]))
          end,
          "indexes" => table["indexes"].map { outbound_index(it, table, classes) },
          "extended_statistics" => table["extended_statistics"].map { outbound_extended(it, table, classes) } }
      end

      def outbound_index(index, table, classes)
        classified = expression_classes(index["definition"], table, classes)
        { "name" => index["name"], "definition" => index["definition"],
          "columns" => index["columns"].map { |name, row| outbound_column(name, row, classified) } }
      end

      MCV_KEYS = %w[most_common_vals most_common_val_nulls most_common_freqs most_common_base_freqs].freeze

      def outbound_extended(object, table, classes)
        classified = expression_classes(object["definition"], table, classes)
        object.slice("schema", "name", "definition", "kinds", "n_distinct", "dependencies").merge(
          MCV_KEYS.to_h do |key|
            keep = key.end_with?("_vals", "_nulls") ? classified["low_cardinality"] : !classified["pii"]
            [key, (object[key] if keep)]
          end
        )
      end

      # {"pii", "low_cardinality"} for an index or statistics object, from
      # the classes of the base columns its definition names.
      def expression_classes(definition, table, classes)
        bases = base_columns(definition).map { classes[[table["schema"], table["name"], it]] }
        return { "pii" => true, "low_cardinality" => false } if bases.empty? || bases.any? { it.nil? || it["pii"] }

        { "pii" => false, "low_cardinality" => bases.all? { it["low_cardinality"] } }
      end

      # The column names a CREATE INDEX or CREATE STATISTICS definition
      # names, or [] when it won't parse.
      def base_columns(definition)
        names = []
        collect_names(PgQuery.parse(definition).tree.stmts.first.stmt.to_h, names)
        names.compact.uniq
      rescue PgQuery::ParseError
        []
      end

      def collect_names(node, names)
        case node
        when Hash
          node.each do |key, value|
            names << node_name(key, value)
            collect_names(value, names)
          end
        when Array then node.each { collect_names(it, names) }
        end
      end

      # The column a ColumnRef, or a plain IndexElem or StatsElem, names.
      # A ColumnRef that ends in * counts as "*", which no column is, so it
      # fails closed.
      def node_name(key, value)
        case key
        when :column_ref then value[:fields].last.dig(:string, :sval) || "*"
        when :index_elem, :stats_elem then value[:name] unless value[:name].to_s.empty?
        end
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
