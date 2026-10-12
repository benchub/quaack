# frozen_string_literal: true

require "json"
require "pg_query"
require_relative "../arena_schema"
require_relative "../table_name"
require_relative "tree"

module Quaack
  module Enclave
    module Fuzz
      # What the search knows about its tables, from arena's pg_catalog.
      # The footprint is the tables the two queries name. The catalog covers
      # them and every table they reference by foreign key, however far up,
      # since lift builds parent rows there. Foreign keys carry their names,
      # NOT VALID ones too (Postgres checks those on insert), so the session
      # can drop the ones that leave the footprint (dropped) and keep the
      # rest (kept).
      class Catalog
        ForeignKey = Data.define(:name, :child, :columns, :parent, :parent_columns)

        FOREIGN_KEYS_SQL = <<~SQL
          SELECT c.conname,
                 pg_catalog.array_to_json(ARRAY(
                   SELECT a.attname FROM pg_catalog.unnest(c.conkey) WITH ORDINALITY k(n, o)
                   JOIN pg_catalog.pg_attribute a
                     ON a.attrelid OPERATOR(pg_catalog.=) c.conrelid AND a.attnum OPERATOR(pg_catalog.=) k.n
                   ORDER BY k.o)),
                 pn.nspname, pc.relname,
                 pg_catalog.array_to_json(ARRAY(
                   SELECT a.attname FROM pg_catalog.unnest(c.confkey) WITH ORDINALITY k(n, o)
                   JOIN pg_catalog.pg_attribute a
                     ON a.attrelid OPERATOR(pg_catalog.=) c.confrelid AND a.attnum OPERATOR(pg_catalog.=) k.n
                   ORDER BY k.o))
          FROM pg_catalog.pg_constraint c
          JOIN pg_catalog.pg_class pc ON pc.oid OPERATOR(pg_catalog.=) c.confrelid
          JOIN pg_catalog.pg_namespace pn ON pn.oid OPERATOR(pg_catalog.=) pc.relnamespace
          WHERE c.conrelid OPERATOR(pg_catalog.=) $1::pg_catalog.regclass AND c.contype OPERATOR(pg_catalog.=) 'f'
          ORDER BY c.conname
        SQL

        attr_reader :footprint, :schema, :kept, :dropped

        def initialize(conn, footprint)
          @footprint = footprint
          @foreign_keys = closure(conn)
          @schema = ArenaSchema.load_closure(conn, @foreign_keys.keys)
          @kept, @dropped = footprint.flat_map { foreign_keys(it) }.partition { footprint.include?(it.parent) }
          @checks = {}
        end

        def columns(table) = schema.columns(table)

        def column(table, name) = schema.column(table, name)

        def foreign_keys(table) = @foreign_keys.fetch(table)

        # Each unique key's columns, sorted: primary keys, unique
        # constraints and indexes, and an expression index's key columns.
        def unique_keys(table)
          constraints = schema.constraints(table)
          (constraints.uniques + constraints.expressions.map(&:key_columns)).reject(&:empty?).map(&:sort).uniq
        end

        # The CHECK expressions, the table's and its domains', that read
        # only this column.
        def checks(table, column)
          @checks[table] ||= schema.constraints(table).checks.filter_map { single_column(it) }
                                   .group_by(&:first).transform_values { it.map(&:last) }
          @checks[table].fetch(column, [])
        end

        private

        def closure(conn)
          found = {}
          queue = footprint.dup
          until queue.empty?
            table = queue.shift
            next if found.key?(table)

            found[table] = read_foreign_keys(conn, table)
            queue.concat(found[table].map(&:parent))
          end
          found
        end

        def read_foreign_keys(conn, table)
          rows = conn.exec_params(FOREIGN_KEYS_SQL, [ArenaSchema.regclass(conn, table)]).values
          rows.map do |name, cols, schema, rel, pcols|
            ForeignKey.new(name:, child: table, columns: JSON.parse(cols), parent: TableName.new(schema:, name: rel),
                           parent_columns: JSON.parse(pcols))
          end
        end

        def single_column(definition)
          expression = definition.delete_prefix("CHECK ").delete_suffix(" NOT VALID")
          columns = Tree.column_refs(PgQuery.parse("SELECT #{expression}").tree.to_h).uniq
          [columns.first, expression] if columns.size == 1
        rescue PgQuery::ParseError
          nil
        end
      end
    end
  end
end
