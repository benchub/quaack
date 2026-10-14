# frozen_string_literal: true

require "pg"
require_relative "../../denormalized_fixture"

module Quaack
  module Enclave
    module Fuzz
      class Session
        # Sends statements in one round trip, and gives each its [result,
        # ok]. After a failure Postgres skips the rest, which come back not
        # ok.
        def self.batch(conn, statements)
          conn.send_query(statements.join("\n;\n"))
          results = []
          while (result = conn.get_result)
            results << [result, result.result_status != PG::PGRES_FATAL_ERROR]
          end
          results.fill([nil, false], results.size...statements.size)
        end

        # Puts a world in the session's transaction.
        #
        # prepare, once per transaction, empties the footprint's tables
        # with TRUNCATE, so the trials' rows go to new files that the
        # transaction's ROLLBACK throws away, not into the arena's own. The
        # run server has autovacuum off, so rows rolled back there would
        # stay for the rest of the run, and every later scan of the table
        # would read them (task 20261012-25). Arena's tables are empty, so
        # TRUNCATE takes nothing away; the foreign keys that would stop it,
        # from tables outside the footprint, are dropped first. prepare then
        # drops the foreign keys that leave the footprint (Catalog#dropped)
        # and works out the honoured copies' UPDATEs (DenormalizedFixture).
        # load rolls back to the
        # session's savepoint, inserts each table's rows in one INSERT, in
        # the world's order so parents load first, and runs the UPDATEs.
        class Loader
          # A copy's UPDATE, recorded by prepare and run by load.
          Captured = Data.define(:rows)

          # The foreign keys from tables TRUNCATE won't empty to ones it
          # will, the footprint's and their children's, which it won't
          # pass. One a partition inherits is dropped where it was declared.
          REFERENCES_SQL = <<~SQL
            WITH RECURSIVE emptied AS (
              SELECT pg_catalog.unnest($1::pg_catalog.regclass[])::pg_catalog.oid AS relid
              UNION
              SELECT i.inhrelid FROM pg_catalog.pg_inherits i
              JOIN emptied e ON i.inhparent OPERATOR(pg_catalog.=) e.relid
            ), blocking AS (
              SELECT c.oid, c.conparentid FROM pg_catalog.pg_constraint c
              WHERE c.contype OPERATOR(pg_catalog.=) 'f'
                AND c.confrelid OPERATOR(pg_catalog.=) ANY (ARRAY(SELECT relid FROM emptied))
                AND NOT c.conrelid OPERATOR(pg_catalog.=) ANY (ARRAY(SELECT relid FROM emptied))
              UNION
              SELECT p.oid, p.conparentid FROM pg_catalog.pg_constraint p
              JOIN blocking b ON p.oid OPERATOR(pg_catalog.=) b.conparentid
            )
            SELECT DISTINCT n.nspname, r.relname, c.conname
            FROM blocking b
            JOIN pg_catalog.pg_constraint c ON c.oid OPERATOR(pg_catalog.=) b.oid
            JOIN pg_catalog.pg_class r ON r.oid OPERATOR(pg_catalog.=) c.conrelid
            JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) r.relnamespace
            WHERE b.conparentid OPERATOR(pg_catalog.=) 0
          SQL

          def initialize(conn, catalog, honour)
            @conn = conn
            @catalog = catalog
            @honour = honour
          end

          def prepare
            empty
            @catalog.dropped.each { @conn.exec("ALTER TABLE #{table_sql(it.child)} DROP CONSTRAINT #{quote(it.name)}") }
            @updates = capture
          end

          # Whether the world loaded.
          def load(rows)
            ok = Session.batch(@conn, ["ROLLBACK TO SAVEPOINT quaack_base", *inserts(rows)]).all?(&:last)
            ok && @updates.all? { |sql, params| attempt { @conn.exec_params(sql, params) } }
          end

          private

          def empty
            tables = @catalog.footprint.map { table_sql(it) }
            references = @conn.exec_params(REFERENCES_SQL, [PG::TextEncoder::Array.new.encode(tables)]).values
            references.each do |schema, table, name|
              @conn.exec("ALTER TABLE #{quote(schema)}.#{quote(table)} DROP CONSTRAINT #{quote(name)}")
            end
            @conn.exec("TRUNCATE #{tables.join(", ")}")
          end

          def inserts(rows) = rows.chunk_while { |a, b| a.table == b.table }.flat_map { insert(it) }

          def insert(group)
            table = table_sql(group.first.table)
            columns = group.flat_map { it.cells.keys }.uniq
            return Array.new(group.size, "INSERT INTO #{table} DEFAULT VALUES") if columns.empty?

            values = group.map { row_sql(columns, it) }
            ["INSERT INTO #{table} (#{columns.map { quote(it) }.join(", ")}) OVERRIDING SYSTEM VALUE " \
             "VALUES (#{values.join("), (")})"]
          end

          def row_sql(columns, row) = columns.map { literal(row.cells, it) }.join(", ")

          def literal(cells, column)
            return "DEFAULT" unless cells.key?(column)

            cells[column].nil? ? "NULL" : @conn.escape_literal(cells[column])
          end

          # Working the UPDATEs out reads the catalog and drops the foreign
          # keys on each copy column, which run now; the UPDATEs run in
          # each trial.
          def capture
            updates = []
            statement = lambda do |sql, params = [], **|
              next Captured.new(rows: @conn.exec_params(sql, params).values) unless sql.match?(/\AUPDATE /)

              updates << [sql, params]
              Captured.new(rows: [])
            end
            DenormalizedFixture.load(@honour, statement, method(:quote))
            updates
          end

          def attempt
            yield
            true
          rescue PG::Error
            false
          end

          def table_sql(table) = "#{quote(table.schema)}.#{quote(table.name)}"

          def quote(name) = @conn.quote_ident(name)
        end
      end
    end
  end
end
