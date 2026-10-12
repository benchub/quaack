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
        # prepare, once per transaction, drops the foreign keys that leave
        # the footprint (Catalog#dropped) and works out the honoured
        # copies' UPDATEs (DenormalizedFixture). load rolls back to the
        # session's savepoint, inserts each table's rows in one INSERT, in
        # the world's order so parents load first, and runs the UPDATEs.
        class Loader
          # A copy's UPDATE, recorded by prepare and run by load.
          Captured = Data.define(:rows)

          def initialize(conn, catalog, honour)
            @conn = conn
            @catalog = catalog
            @honour = honour
          end

          def prepare
            @catalog.dropped.each { @conn.exec("ALTER TABLE #{table_sql(it.child)} DROP CONSTRAINT #{quote(it.name)}") }
            @updates = capture
          end

          # Whether the world loaded.
          def load(rows)
            ok = Session.batch(@conn, ["ROLLBACK TO SAVEPOINT quaack_base", *inserts(rows)]).all?(&:last)
            ok && @updates.all? { |sql, params| attempt { @conn.exec_params(sql, params) } }
          end

          private

          def inserts(rows) = rows.chunk_while { |a, b| a.table == b.table }.flat_map { insert(it) }

          def insert(group)
            table = table_sql(group.first.table)
            columns = group.flat_map { it.cells.keys }.uniq
            return Array.new(group.size, "INSERT INTO #{table} DEFAULT VALUES") if columns.empty?

            values = group.map { row_sql(columns, it) }
            ["INSERT INTO #{table} (#{columns.map { quote(it) }.join(", ")}) OVERRIDING SYSTEM VALUE " \
             "VALUES #{values.join(", ")}"]
          end

          def row_sql(columns, row) = "(#{columns.map { literal(row.cells, it) }.join(", ")})"

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
              next Captured.new(rows: @conn.exec_params(sql, params).values) unless sql.start_with?("UPDATE ")

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
