# frozen_string_literal: true

require_relative "table_name"
require_relative "index_candidate"
require_relative "statistics"
require_relative "inventory/production"
require_relative "planner_statistics/catalog"

module Quaack
  module Enclave
    # README 3c: the planner statistics for the query's tables and their
    # indexes, extended statistics included, and each index's definition
    # and size. It all goes into the governed store. MCV lists and histogram
    # bounds hold real values, so the entry is value-class data, and nothing
    # here leaves the enclave.
    #
    #   result = PlannerStatistics.run(store:, relations: Relations.check(sql, settings, conn).relations,
    #                                  connection: conn)
    #   result.statistics            # => Statistics, for 5a-1, 5a-2, and 5a-3
    #   result.few_distinct          # => [[TableName(public.orders), "status"]], for 3f
    #   store.read("statistics")     # => { "tables" => [{ "schema" => "public", "name" => "orders", ... }] }
    #   PlannerStatistics.load(store) # => the same Result, rebuilt from the store
    #
    # The inputs:
    # - relations: the qualified TableNames from Relations.check, so every
    #   one is a plain table.
    # - connection: a PG connection to the production database, from
    #   Inventory::Production.connect. Everything is read inside one
    #   read-only, repeatable read transaction (Inventory::Production.read_only),
    #   so the reads share one snapshot, and it's rolled back after.
    #
    # The stored entry holds, for each table in the order given:
    # - schema, name, reltuples, relpages, and column_names, every column in
    #   attnum order.
    # - columns: each column's own pg_stats row (inherited = false), keyed by
    #   name, with null_frac, avg_width, n_distinct, most_common_vals,
    #   most_common_freqs, histogram_bounds, and correlation. The value
    #   arrays are Strings in the text form pg_stats prints (see PgArray), or
    #   nil. A column with no pg_stats row isn't there. The element and
    #   range statistics (most_common_elems, range_length_histogram, and the
    #   like) aren't read: no step uses them yet.
    # - indexes: each valid index, sorted by name, with its name, definition
    #   (pg_get_indexdef), size_bytes (pg_relation_size), and columns, the
    #   pg_stats rows Postgres keeps for an expression index's expressions,
    #   in the same form. An invalid index (indisvalid false), such as one
    #   left by a failed CREATE INDEX CONCURRENTLY, is left out, so 5a-3
    #   can't count it as covering.
    # - extended_statistics: each CREATE STATISTICS object on the table,
    #   sorted by schema and name, with its definition
    #   (pg_get_statisticsobjdef), kinds (stxkind), and its pg_stats_ext
    #   data: n_distinct and dependencies as the text Postgres prints, and
    #   most_common_vals (an Array of Arrays of Strings), most_common_val_nulls,
    #   most_common_freqs, and most_common_base_freqs. The data is nil until
    #   ANALYZE fills it. Statistics on expressions (pg_stats_ext_exprs)
    #   aren't read.
    #
    # The Result's statistics is built from that entry, with each index as
    # IndexCandidate.from_ddl reads its definition, sources [:existing], or
    # nil where it can't. few_distinct is each column, in table and then
    # attnum order, whose distinct count (TableStatistics#distinct_count, as
    # 5a-1 counts) is known and under LOW_CARDINALITY_LIMIT, as
    # [TableName, column] pairs, the shape Dedupe's low_cardinality takes.
    # It isn't the low-cardinality set yet: README 3f takes out the PII
    # columns first.
    #
    # Refusals raise Error, with a rule and a message naming only tables:
    # unknown_relation (the catalog doesn't have one), and
    # inheritance_parent (a table has inheritance children, so pg_stats has
    # two rows for each column, and v1 doesn't choose between them). A
    # failed read raises Inventory::Error production_read_failed, with the
    # SQLSTATE and no cause, since Postgres's message can quote a value.
    # A refusal stores nothing.
    module PlannerStatistics
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
          super("#{rule}: #{detail}")
        end
      end

      Result = Data.define(:statistics, :few_distinct)

      ENTRY = "statistics"

      # README 3f: a column is low-cardinality with fewer than this many
      # distinct values.
      LOW_CARDINALITY_LIMIT = 50

      module_function

      def run(store:, relations:, connection:)
        data = Inventory::Production.read_only(connection) do
          { "tables" => relations.map { Catalog.table(it, connection) } }
        end
        store.write(ENTRY, data)
        build(data)
      end

      # The Result from the entry an earlier run stored.
      def load(store) = build(store.read(ENTRY))

      def build(data)
        tables = data["tables"].map { table_statistics(it) }
        few = tables.flat_map do |stats|
          stats.column_names.select { few_distinct?(stats, it) }.map { [stats.name, it] }
        end
        Result.new(statistics: Statistics.new(tables:), few_distinct: few)
      end

      def few_distinct?(stats, column)
        count = stats.column?(column) && stats.distinct_count(column)
        count && count < LOW_CARDINALITY_LIMIT
      end

      def table_statistics(table)
        name = TableName.new(schema: table["schema"], name: table["name"])
        TableStatistics.new(
          name:, reltuples: table["reltuples"], column_names: table["column_names"],
          columns: table["columns"].transform_values { column_statistics(it) },
          indexes: table["indexes"].to_h do |index|
            [index["name"], IndexCandidate.from_ddl(index["definition"], sources: [:existing])]
          end
        )
      end

      def column_statistics(row)
        ColumnStatistics.new(n_distinct: row["n_distinct"], null_frac: row["null_frac"],
                             correlation: row["correlation"], most_common_vals: row["most_common_vals"],
                             most_common_freqs: row["most_common_freqs"])
      end
    end
  end
end
