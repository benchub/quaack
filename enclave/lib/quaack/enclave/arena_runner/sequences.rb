# frozen_string_literal: true

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

        # A column with no sequence matches no row, so it's a no-op. The
        # value is kept within the sequence's bounds, since a fixture may
        # hold a boundary value below its minimum.
        SETVAL_SQL = <<~SQL
          SELECT pg_catalog.setval(s.seqrelid, LEAST(GREATEST($3::bigint, s.seqmin), s.seqmax))
          FROM pg_catalog.pg_sequence s
          WHERE s.seqrelid OPERATOR(pg_catalog.=) pg_catalog.pg_get_serial_sequence($1, $2)::pg_catalog.regclass
        SQL

        module_function

        # Runs each setval through the runner's statement. table_sql quotes a
        # TableName.
        def advance(rows, table_sql, statement)
          maxima(rows).each do |(table, column), max|
            statement.call(SETVAL_SQL, [table_sql.call(table), column, max],
                           step: :load, rule: :fixture_load_failed, index: nil)
          end
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
