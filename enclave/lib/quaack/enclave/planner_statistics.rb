# frozen_string_literal: true

require_relative "table_name"
require_relative "index_candidate"
require_relative "statistics"
require_relative "inventory/production"
require_relative "planner_statistics/catalog"

module Quaack
  module Enclave
    # DESIGN.md's statistics: the planner statistics for the query's tables and their
    # indexes, extended statistics included, and each index's definition
    # and size. It all goes into the governed store. MCV lists and histogram
    # bounds hold real values, so the entry is value-class data, and nothing
    # here leaves the enclave.
    #
    #   result = PlannerStatistics.run(store:, relations: Relations.check(sql, settings, conn).relations,
    #                                  connection: conn)
    #   result.statistics            # => Statistics, for index-from-query, index-from-plan, and index-dedupe
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
    # - text_columns: the text-like columns, in attnum order: those whose
    #   type is in Postgres's string category (text, varchar, char, name,
    #   citext, or a domain over one), for classify's heuristic.
    # - sendable_columns: the columns whose MCV values may leave if classify
    #   marks them low-cardinality, in attnum order: the text-like ones, and
    #   those whose type is on ColumnTypes::SENDABLE_TYPES (numbers, money, oid,
    #   boolean, the date and time types, and uuid) or an enum, or a domain
    #   over one at any depth. Every other column, an array of any type
    #   included, is withheld: classify never marks it low-cardinality.
    # - clock_columns: each column whose type, or its domain's base type, is
    #   date, timestamp, or timestamptz, mapped to that type, for clock-anchor's
    #   clock literals.
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
    #   left by a failed CREATE INDEX CONCURRENTLY, is left out, so index-dedupe
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
    # nil where it can't. DESIGN.md's classify (PiiClassification) reads the entry for
    # the low-cardinality set that Dedupe takes.
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

      Result = Data.define(:statistics)

      ENTRY = "statistics"

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
        Result.new(statistics: Statistics.new(tables: data["tables"].map { table_statistics(it) }))
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
