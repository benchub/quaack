# frozen_string_literal: true

require "json"
require_relative "../pg_array"

module Quaack
  module Enclave
    module PlannerStatistics
      # The catalog reads behind PlannerStatistics.run: one table's entry, as
      # plain JSON data for the store. See PlannerStatistics for its form.
      # The caller holds the read-only transaction.
      module Catalog
        TABLE_SQL = <<~SQL
          SELECT c.oid, c.reltuples, c.relpages,
                 EXISTS (SELECT FROM pg_catalog.pg_inherits i WHERE i.inhparent = c.oid)
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = $1 AND c.relname = $2
        SQL

        # A column is text-like when its type is in the string category:
        # text, varchar, char, name, citext, and any domain over one, since
        # a domain takes its base type's category.
        #
        # A column is a clock column when its type, or a domain's base type,
        # is date, timestamp, or timestamptz: 3h anchors a clock literal
        # compared with one (see ClockLiterals).
        COLUMNS_SQL = <<~SQL
          SELECT a.attname, t.typcategory = 'S',
                 CASE COALESCE(NULLIF(t.typbasetype, 0), t.oid)
                   WHEN 'pg_catalog.date'::pg_catalog.regtype THEN 'date'
                   WHEN 'pg_catalog.timestamp'::pg_catalog.regtype THEN 'timestamp'
                   WHEN 'pg_catalog.timestamptz'::pg_catalog.regtype THEN 'timestamptz'
                 END
          FROM pg_catalog.pg_attribute a
          JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
          WHERE a.attrelid = $1 AND a.attnum > 0 AND NOT a.attisdropped
          ORDER BY a.attnum
        SQL

        # One relation's own pg_stats rows. An index's are its expressions'.
        PG_STATS_SQL = <<~SQL
          SELECT attname, null_frac, avg_width, n_distinct, most_common_vals::text, most_common_freqs::text,
                 histogram_bounds::text, correlation
          FROM pg_catalog.pg_stats WHERE schemaname = $1 AND tablename = $2 AND NOT inherited
          ORDER BY attname COLLATE "C"
        SQL

        INDEXES_SQL = <<~SQL
          SELECT c.relname, pg_catalog.pg_get_indexdef(i.indexrelid), pg_catalog.pg_relation_size(i.indexrelid)
          FROM pg_catalog.pg_index i
          JOIN pg_catalog.pg_class c ON c.oid = i.indexrelid
          WHERE i.indrelid = $1 AND i.indisvalid
          ORDER BY c.relname COLLATE "C"
        SQL

        # array_to_json, because most_common_vals is a two-dimensional
        # text[]. Postgres writes the JSON, so it always parses.
        EXTENDED_SQL = <<~SQL
          SELECT n.nspname, s.stxname, pg_catalog.pg_get_statisticsobjdef(s.oid), s.stxkind::text,
                 d.n_distinct::text, d.dependencies::text, array_to_json(d.most_common_vals),
                 array_to_json(d.most_common_val_nulls), array_to_json(d.most_common_freqs),
                 array_to_json(d.most_common_base_freqs)
          FROM pg_catalog.pg_statistic_ext s
          JOIN pg_catalog.pg_namespace n ON n.oid = s.stxnamespace
          LEFT JOIN pg_catalog.pg_stats_ext d
            ON d.statistics_schemaname = n.nspname AND d.statistics_name = s.stxname AND NOT d.inherited
          WHERE s.stxrelid = $1
          ORDER BY n.nspname COLLATE "C", s.stxname COLLATE "C"
        SQL

        COLUMN_KEYS = %w[null_frac avg_width n_distinct most_common_vals most_common_freqs histogram_bounds
                         correlation].freeze
        EXTENDED_KEYS = %w[schema name definition kinds n_distinct dependencies most_common_vals
                           most_common_val_nulls most_common_freqs most_common_base_freqs].freeze

        module_function

        def table(table, connection)
          oid, reltuples, relpages, children = connection.exec_params(TABLE_SQL,
                                                                      [table.schema, table.name]).values.first
          raise Error.new("unknown_relation", "#{table} doesn't exist") unless oid
          raise Error.new("inheritance_parent", "#{table} has inheritance children") if children == "t"

          { "schema" => table.schema, "name" => table.name, "reltuples" => Float(reltuples),
            "relpages" => Integer(relpages, 10), **contents(table, oid, connection) }
        end

        def contents(table, oid, connection)
          columns = connection.exec_params(COLUMNS_SQL, [oid]).values
          { "column_names" => columns.map(&:first),
            "text_columns" => columns.filter_map { |name, text| name if text == "t" },
            "clock_columns" => columns.filter_map { |name, _, clock| [name, clock] if clock }.to_h,
            "columns" => pg_stats(connection, table.schema, table.name),
            "indexes" => indexes(connection, table.schema, oid),
            "extended_statistics" => extended(connection, oid) }
        end

        def pg_stats(connection, schema, relation)
          connection.exec_params(PG_STATS_SQL, [schema, relation]).values.to_h do |name, *row|
            [name, COLUMN_KEYS.zip(column(row)).to_h]
          end
        end

        def column(row)
          null_frac, avg_width, n_distinct, vals, freqs, bounds, correlation = row
          [Float(null_frac), Integer(avg_width, 10), Float(n_distinct), array(vals), array(freqs)&.map { Float(it) },
           array(bounds), correlation && Float(correlation)]
        end

        def indexes(connection, schema, oid)
          connection.exec_params(INDEXES_SQL, [oid]).values.map do |name, definition, size|
            { "name" => name, "definition" => definition, "size_bytes" => Integer(size, 10),
              "columns" => pg_stats(connection, schema, name) }
          end
        end

        def extended(connection, oid)
          connection.exec_params(EXTENDED_SQL, [oid]).values.map do |schema, name, definition, kinds, *data|
            n_distinct, dependencies, *arrays = data
            EXTENDED_KEYS.zip([schema, name, definition, PgArray.parse(kinds), n_distinct, dependencies,
                               *arrays.map { it && JSON.parse(it) }]).to_h
          end
        end

        def array(text) = text && PgArray.parse(text)
      end
    end
  end
end
