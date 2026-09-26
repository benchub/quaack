# frozen_string_literal: true

require_relative "table_name"

module Quaack
  module Enclave
    # What step 9 needs to know about the tables it builds fixtures for,
    # read from arena's pg_catalog: each column's type, nullability, and
    # default.
    #
    #   schema = ArenaSchema.load(arena_connection, [table_name, ...])
    #   schema.column_names          # => { table_name => ["id", ...] }, for PredicateAtoms
    #   schema.column(table, "qty")  # => Column(name:, type:, oid:, nullable:, default:)
    #
    # A table that isn't in arena raises KeyError. Everything here is
    # catalog data, never a row's value.
    class ArenaSchema
      Column = Data.define(:name, :type, :oid, :nullable, :default)

      COLUMNS_SQL = <<~SQL
        SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.atttypid::int,
               NOT a.attnotnull,
               CASE WHEN a.attidentity <> '' OR a.attgenerated <> '' THEN 'generated'
                    ELSE pg_get_expr(d.adbin, d.adrelid) END
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
      SQL

      def self.load(conn, tables)
        new(tables.uniq.to_h { |table| [table, read_columns(conn, table)] })
      end

      def self.regclass(conn, table) = "#{conn.quote_ident(table.schema)}.#{conn.quote_ident(table.name)}"

      def self.read_columns(conn, table)
        exists = conn.exec_params("SELECT to_regclass($1)", [regclass(conn, table)]).getvalue(0, 0)
        raise KeyError, "table #{table} isn't in arena" unless exists

        conn.exec_params(COLUMNS_SQL, [regclass(conn, table)]).values.map do |name, type, oid, nullable, default|
          Column.new(name:, type:, oid: Integer(oid), nullable: nullable == "t", default:)
        end
      end

      attr_reader :tables

      def initialize(columns)
        @columns = columns
        @tables = columns.keys
      end

      def column_names = @columns.transform_values { |cols| cols.map(&:name) }

      def columns(table) = @columns.fetch(table)

      def column(table, name) = columns(table).find { |c| c.name == name } || raise(KeyError, "no column #{name}")
    end
  end
end
