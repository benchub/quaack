# frozen_string_literal: true

require "json"

module Quaack
  module Enclave
    class ArenaRunner
      # Values set explicitly on an identity or serial column don't move its
      # sequence, so an insert that leaves the column out could collide with
      # a fixture row. After loading, the runner moves each such sequence to
      # the column's max in the fixture. setval isn't rolled back, but the
      # value it sets depends only on the fixture.
      module Sequences
        BIGINT = (-(2**63))..((2**63) - 1)

        # Every column at once, from a JSON list of table, column and max,
        # so a wide fixture costs one round trip (task 20261011-13). A column
        # with no sequence matches no row, so it's a no-op. Each sequence
        # belongs to one column, so no two rows set the same one. The value
        # is kept within the sequence's bounds, since a fixture may hold a
        # boundary value below its minimum.
        SETVAL_SQL = <<~SQL
          SELECT pg_catalog.setval(s.seqrelid, LEAST(GREATEST(v.m, s.seqmin), s.seqmax))
          FROM pg_catalog.json_to_recordset($1::pg_catalog.json)
            AS v(t pg_catalog.text, c pg_catalog.text, m pg_catalog.int8)
          JOIN pg_catalog.pg_sequence s
            ON s.seqrelid OPERATOR(pg_catalog.=) pg_catalog.pg_get_serial_sequence(v.t, v.c)::pg_catalog.regclass
        SQL

        module_function

        # Runs each setval through the runner's statement. table_sql quotes a
        # TableName.
        def advance(rows, table_sql, statement)
          found = maxima(rows).map { |(table, column), max| { t: table_sql.call(table), c: column, m: max } }
          return if found.empty?

          statement.call(SETVAL_SQL, [JSON.generate(found)], step: :load, rule: :fixture_load_failed, index: nil)
        end

        # { [table, column] => max } over the rows' integer values.
        def maxima(rows)
          rows.each_with_object({}) do |row, maxima|
            row.columns.zip(row.values) do |column, value|
              n = value.is_a?(String) && Integer(value, 10, exception: false)
              next unless n && BIGINT.cover?(n)

              key = [row.table, column]
              maxima[key] = [maxima[key], n].compact.max
            end
          end
        end
      end
    end
  end
end
