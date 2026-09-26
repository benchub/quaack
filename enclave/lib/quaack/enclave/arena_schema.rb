# frozen_string_literal: true

require "json"
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
               CASE WHEN a.attgenerated <> '' THEN 'generated' WHEN a.attidentity <> '' THEN 'identity'
                    ELSE pg_get_expr(d.adbin, d.adrelid) END
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
      SQL

      # A foreign key: columns of the child reference parent_columns of
      # parent, a TableName.
      ForeignKey = Data.define(:columns, :parent, :parent_columns)
      # Each table's primary key, unique constraints, and unique indexes (as
      # lists of column names), foreign keys, and validated CHECK
      # expressions, as pg_get_constraintdef prints them. A partial unique
      # index counts as always unique, which is conservative.
      # expression_unique is whether a unique index has an expression key.
      Constraints = Data.define(:uniques, :foreign_keys, :checks, :expression_unique)

      # Unique indexes no constraint owns: their key columns (not INCLUDE
      # ones), and whether any key is an expression.
      UNIQUE_INDEXES_SQL = <<~SQL
        SELECT array_to_json(ARRAY(SELECT a.attname FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(n, o)
                 JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.n
                 WHERE k.o <= i.indnkeyatts ORDER BY k.o)),
               i.indexprs IS NOT NULL
        FROM pg_index i
        WHERE i.indrelid = $1::regclass AND i.indisunique AND i.indisvalid
          AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid AND c.conrelid = i.indrelid)
      SQL

      CONSTRAINTS_SQL = <<~SQL
        SELECT c.contype,
               array_to_json(ARRAY(SELECT a.attname FROM unnest(c.conkey) WITH ORDINALITY k(n, o)
                 JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n ORDER BY k.o)),
               pn.nspname, pc.relname,
               array_to_json(ARRAY(SELECT a.attname FROM unnest(c.confkey) WITH ORDINALITY k(n, o)
                 JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.n ORDER BY k.o)),
               pg_get_constraintdef(c.oid)
        FROM pg_constraint c
        LEFT JOIN pg_class pc ON pc.oid = c.confrelid
        LEFT JOIN pg_namespace pn ON pn.oid = pc.relnamespace
        WHERE c.conrelid = $1::regclass AND c.contype IN ('p', 'u', 'f', 'c') AND c.convalidated
        ORDER BY c.contype, c.conname
      SQL

      def self.load(conn, tables)
        new(tables.uniq.to_h { |table| [table, read_columns(conn, table)] })
      end

      # The tables and every table they reference by foreign key, however
      # far up, with their constraints.
      def self.load_closure(conn, tables)
        constraints = {}
        queue = tables.dup
        until queue.empty?
          table = queue.shift
          next if constraints.key?(table)

          constraints[table] = read_constraints(conn, table)
          queue.concat(constraints[table].foreign_keys.map(&:parent))
        end
        new(constraints.keys.to_h { |t| [t, read_columns(conn, t)] }, constraints)
      end

      def self.read_constraints(conn, table)
        rows = conn.exec_params(CONSTRAINTS_SQL, [regclass(conn, table)]).values
        of = rows.group_by(&:first)
        indexes, expression_unique = unique_indexes(conn, table)
        Constraints.new(uniques: keys(of) + indexes,
                        expression_unique:,
                        foreign_keys: of.fetch("f", []).map { |r| foreign_key(r) },
                        checks: checks(conn, table, of))
      end

      # The unique indexes' column lists, and whether any has an expression.
      def self.unique_indexes(conn, table)
        rows = conn.exec_params(UNIQUE_INDEXES_SQL, [regclass(conn, table)]).values
        [rows.map { |cols, _| JSON.parse(cols) }, rows.any? { |_, expr| expr == "t" }]
      end

      def self.keys(of) = (of.fetch("p", []) + of.fetch("u", [])).map { |r| JSON.parse(r[1]) }

      def self.checks(conn, table, of) = of.fetch("c", []).map(&:last) + DomainChecks.read(conn, regclass(conn, table))

      def self.foreign_key(row)
        _, cols, schema, name, parent_cols = row
        ForeignKey.new(columns: JSON.parse(cols), parent: TableName.new(schema:, name:),
                       parent_columns: JSON.parse(parent_cols))
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

      def initialize(columns, constraints = {})
        @columns = columns
        @constraints = constraints
        @tables = columns.keys
      end

      def constraints(table) = @constraints.fetch(table)

      def column_names = @columns.transform_values { |cols| cols.map(&:name) }

      def columns(table) = @columns.fetch(table)

      def column(table, name) = columns(table).find { |c| c.name == name } || raise(KeyError, "no column #{name}")
    end
  end
end

require_relative "arena_schema/domain_checks"
