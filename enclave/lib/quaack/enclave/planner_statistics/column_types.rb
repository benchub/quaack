# frozen_string_literal: true

module Quaack
  module Enclave
    module PlannerStatistics
      # The column-type reads behind Catalog: which of one table's columns
      # are text-like, sendable, and clock columns. See PlannerStatistics
      # for the stored form.
      module ColumnTypes
        # A column is text-like when its type is in the string category:
        # text, varchar, char, name, citext, and any domain over one, since
        # a domain takes its base type's category.
        #
        # A column is sendable when it's text-like, or its type is on
        # SENDABLE_TYPES or an enum, or a domain over one at any depth: the
        # recursive CTE follows a domain down to its base type. Only a
        # sendable column's MCV values may leave the enclave (see
        # PiiClassification). Any other type is withheld, so a type this
        # doesn't know, such as an extension's, fails closed. An array
        # isn't sendable, whatever its element type.
        #
        # A column is a clock column when its type, or a domain's base type,
        # is date, timestamp, or timestamptz: clock-anchor anchors a clock literal
        # compared with one (see ClockLiterals).
        #
        # Every comparison names pg_catalog's operator, so one planted ahead
        # of it on the search_path can't make a type look text-like,
        # sendable, or a clock type.
        SENDABLE_TYPES = %w[int2 int4 int8 numeric float4 float8 money oid bool date time timetz timestamp
                            timestamptz interval uuid].freeze
        SENDABLE_OIDS = "ARRAY[#{SENDABLE_TYPES.map { "'pg_catalog.#{it}'" }.join(", ")}]" \
                        "::pg_catalog.regtype[]::pg_catalog.oid[]".freeze
        COLUMNS_SQL = <<~SQL.freeze
          SELECT a.attname, t.typcategory OPERATOR(pg_catalog.=) 'S',
                 CASE
                   WHEN base.oid OPERATOR(pg_catalog.=) 'pg_catalog.date'::pg_catalog.regtype::pg_catalog.oid
                     THEN 'date'
                   WHEN base.oid OPERATOR(pg_catalog.=) 'pg_catalog.timestamp'::pg_catalog.regtype::pg_catalog.oid
                     THEN 'timestamp'
                   WHEN base.oid OPERATOR(pg_catalog.=) 'pg_catalog.timestamptz'::pg_catalog.regtype::pg_catalog.oid
                     THEN 'timestamptz'
                 END,
                 t.typcategory OPERATOR(pg_catalog.=) 'S' OR EXISTS (
                   WITH RECURSIVE chain(oid) AS (SELECT t.oid UNION ALL SELECT b.typbasetype FROM chain
                     JOIN pg_catalog.pg_type b ON b.oid OPERATOR(pg_catalog.=) chain.oid
                     WHERE b.typbasetype OPERATOR(pg_catalog.<>) 0)
                   SELECT FROM chain JOIN pg_catalog.pg_type s ON s.oid OPERATOR(pg_catalog.=) chain.oid
                   WHERE s.typtype OPERATOR(pg_catalog.=) 'e' OR s.oid OPERATOR(pg_catalog.=) ANY (#{SENDABLE_OIDS}))
          FROM pg_catalog.pg_attribute a
          JOIN pg_catalog.pg_type t ON t.oid OPERATOR(pg_catalog.=) a.atttypid
          CROSS JOIN LATERAL (SELECT CASE WHEN t.typbasetype OPERATOR(pg_catalog.<>) 0 THEN t.typbasetype
                                          ELSE t.oid END) base(oid)
          WHERE a.attrelid OPERATOR(pg_catalog.=) $1 AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped
          ORDER BY a.attnum
        SQL

        module_function

        # column_names, text_columns, sendable_columns, and clock_columns
        # for the relation whose oid is oid.
        def read(connection, oid)
          columns = connection.exec_params(COLUMNS_SQL, [oid]).values
          { "column_names" => columns.map(&:first),
            "text_columns" => flagged(columns, 1), "sendable_columns" => flagged(columns, 3),
            "clock_columns" => columns.filter_map { |name, _, clock| [name, clock] if clock }.to_h }
        end

        # The names of the columns whose boolean at index is true.
        def flagged(columns, index) = columns.filter_map { |row| row.first if row[index] == "t" }
      end
    end
  end
end
