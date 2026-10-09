# frozen_string_literal: true

require "json"
require_relative "../pg_array"
require_relative "column_types"
require_relative "visibility"

module Quaack
  module Enclave
    module PlannerStatistics
      # The catalog reads behind PlannerStatistics.run: one table's entry, as
      # plain JSON data for the store. See PlannerStatistics for its form.
      # The caller holds the read-only transaction. Every comparison names
      # pg_catalog's operator, and every function and cast pg_catalog's
      # function and type, and every ORDER BY pg_catalog's "C" collation, so
      # one planted ahead of it on the search_path can't change what a read
      # finds, the order it finds it in, or write what it returns.
      module Catalog # rubocop:disable Metrics/ModuleLength
        TABLE_SQL = <<~SQL
          SELECT c.oid, c.reltuples, c.relpages,
                 EXISTS (SELECT FROM pg_catalog.pg_inherits i WHERE i.inhparent OPERATOR(pg_catalog.=) c.oid)
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
          WHERE n.nspname OPERATOR(pg_catalog.=) $1 AND c.relname OPERATOR(pg_catalog.=) $2
        SQL

        # One relation's own pg_stats rows. An index's are its expressions'.
        # With each, its type's array delimiter (typdelim), which array_out
        # prints the value arrays with. A domain has its base type's.
        # inherited is in the ORDER BY so that, were NOT inherited dropped,
        # an inherited row would always come last and win, never by chance.
        PG_STATS_SQL = <<~SQL
          SELECT s.attname, s.null_frac, s.avg_width, s.n_distinct, s.most_common_vals::pg_catalog.text,
                 s.most_common_freqs::pg_catalog.text, s.histogram_bounds::pg_catalog.text, s.correlation,
                 t.typdelim::pg_catalog.text
          FROM pg_catalog.pg_stats s
          JOIN pg_catalog.pg_namespace n ON n.nspname OPERATOR(pg_catalog.=) s.schemaname
          JOIN pg_catalog.pg_class c ON c.relnamespace OPERATOR(pg_catalog.=) n.oid
           AND c.relname OPERATOR(pg_catalog.=) s.tablename
          JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) c.oid
           AND a.attname OPERATOR(pg_catalog.=) s.attname
          JOIN pg_catalog.pg_type t ON t.oid OPERATOR(pg_catalog.=) a.atttypid
          WHERE s.schemaname OPERATOR(pg_catalog.=) $1 AND s.tablename OPERATOR(pg_catalog.=) $2
           AND NOT s.inherited
          ORDER BY s.attname COLLATE pg_catalog."C", s.inherited
        SQL

        INDEXES_SQL = <<~SQL
          SELECT c.relname, pg_catalog.pg_get_indexdef(i.indexrelid), pg_catalog.pg_relation_size(i.indexrelid),
                 i.indisunique OR i.indisprimary OR i.indisexclusion OR EXISTS (
                   SELECT 1 FROM pg_catalog.pg_constraint k WHERE k.conindid OPERATOR(pg_catalog.=) i.indexrelid),
                 s.idx_scan
          FROM pg_catalog.pg_index i
          JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) i.indexrelid
          LEFT JOIN pg_catalog.pg_stat_user_indexes s ON s.indexrelid OPERATOR(pg_catalog.=) i.indexrelid
          WHERE i.indrelid OPERATOR(pg_catalog.=) $1 AND i.indisvalid
          ORDER BY c.relname COLLATE pg_catalog."C"
        SQL

        # array_to_json, because most_common_vals is a two-dimensional
        # text[]. Postgres writes the JSON, so it always parses.
        EXTENDED_SQL = <<~SQL
          SELECT n.nspname, s.stxname, pg_catalog.pg_get_statisticsobjdef(s.oid), s.stxkind::pg_catalog.text,
                 d.n_distinct::pg_catalog.text, d.dependencies::pg_catalog.text,
                 pg_catalog.array_to_json(d.most_common_vals), pg_catalog.array_to_json(d.most_common_val_nulls),
                 pg_catalog.array_to_json(d.most_common_freqs), pg_catalog.array_to_json(d.most_common_base_freqs)
          FROM pg_catalog.pg_statistic_ext s
          JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) s.stxnamespace
          LEFT JOIN pg_catalog.pg_stats_ext d
            ON d.statistics_schemaname OPERATOR(pg_catalog.=) n.nspname
           AND d.statistics_name OPERATOR(pg_catalog.=) s.stxname AND NOT d.inherited
          WHERE s.stxrelid OPERATOR(pg_catalog.=) $1
          ORDER BY n.nspname COLLATE pg_catalog."C", s.stxname COLLATE pg_catalog."C"
        SQL

        COLUMN_KEYS = %w[null_frac avg_width n_distinct most_common_vals most_common_freqs histogram_bounds
                         correlation].freeze
        EXTENDED_KEYS = %w[schema name definition kinds n_distinct dependencies most_common_vals
                           most_common_val_nulls most_common_freqs most_common_base_freqs].freeze

        module_function

        # query is the qualified query, whose columns' statistics must all
        # be ones pg_stats shows (see Visibility). nil checks every column.
        def table(table, connection, query = nil)
          oid, reltuples, relpages, children = connection.exec_params(TABLE_SQL,
                                                                      [table.schema, table.name]).values.first
          raise Error.new("unknown_relation", "#{table} doesn't exist") unless oid
          raise Error.new("inheritance_parent", "#{table} has inheritance children") if children == "t"

          entry = { "schema" => table.schema, "name" => table.name, "reltuples" => Float(reltuples),
                    "relpages" => Integer(relpages, 10), **contents(table, oid, connection) }
          Visibility.check!(table, oid, entry, query, connection)
          entry
        end

        def contents(table, oid, connection)
          columns, skipped = pg_stats(connection, table.schema, table.name)
          utf8({ **ColumnTypes.read(connection, oid), "columns" => columns, "array_statistics_skipped" => skipped,
                                                      "indexes" => indexes(connection, table.schema, oid),
                                                      "extended_statistics" => extended(connection, oid),
                                                      "statistics_hidden" => Hidden.read(connection, oid) })
        end

        # The rows, and the names of the columns whose array statistics were
        # skipped, since their type's array delimiter isn't a comma, which
        # is all PgArray reads. Such a column keeps its scalars, and its
        # most_common_vals, most_common_freqs, and histogram_bounds are nil.
        def pg_stats(connection, schema, relation)
          skipped = []
          rows = connection.exec_params(PG_STATS_SQL, [schema, relation]).values.to_h do |name, *row, delimiter|
            skipped << name unless delimiter == ","
            [name, COLUMN_KEYS.zip(column(row, arrays: delimiter == ",")).to_h]
          end
          [rows, skipped]
        end

        def column(row, arrays:)
          null_frac, avg_width, n_distinct, vals, freqs, bounds, correlation = row
          vals = freqs = bounds = nil unless arrays
          [Float(null_frac), Integer(avg_width, 10), Float(n_distinct), array(vals), array(freqs)&.map { Float(it) },
           array(bounds), correlation && Float(correlation)]
        end

        def indexes(connection, schema, oid)
          connection.exec_params(INDEXES_SQL, [oid]).values.map do |name, definition, size, constrained, scans|
            columns, skipped = pg_stats(connection, schema, name)
            { "name" => name, "definition" => definition, "size_bytes" => Integer(size, 10),
              "constrained" => constrained == "t", "idx_scan" => scans && Integer(scans, 10),
              "columns" => columns, "array_statistics_skipped" => skipped }
          end
        end

        def extended(connection, oid)
          connection.exec_params(EXTENDED_SQL, [oid]).values.map do |row|
            schema, name, definition, kinds, n_distinct, dependencies, *arrays = utf8(row)
            EXTENDED_KEYS.zip([schema, name, definition, PgArray.parse(kinds), n_distinct, dependencies,
                               *arrays.map { it && JSON.parse(it) }]).to_h
          end
        end

        def array(text) = text && PgArray.parse(text)

        # A string from the catalog comes back in the connection's client
        # encoding, the database's own unless the caller set another, such
        # as ISO-8859-1 for a LATIN1 database. The store's JSON is UTF-8, and
        # so are the query's names, so each is transcoded, as SchemaDump
        # does. The connection itself is left alone.
        def utf8(value)
          case value
          when String then value.encode(Encoding::UTF_8)
          when Array then value.map { utf8(it) }
          when Hash then value.to_h { |key, item| [utf8(key), utf8(item)] }
          else value
          end
        end
      end
    end
  end
end
