# frozen_string_literal: true

require "pg"
require_relative "../value_pools"

module Quaack
  module Enclave
    module Fuzz
      # The queries' constants dictionary for one column: each constant the
      # column's type can read, and its near neighbours at the type's
      # resolution, finer than ValuePools'. A neighbour is the value plus a
      # step of STEPS, each with its negation, and for a numeric category,
      # also the value's next step either side: the smallest power of ten
      # from FINEST up that the column's type doesn't round away, so a
      # numeric(10,2) steps 0.01 and a real near 1000 about 0.0001.
      class Dictionary
        STEPS = { "N" => ["1", "-1"],
                  "D" => ["1", "-1", "interval '1 second'", "interval '-1 second'", "interval '1 day'",
                          "interval '-1 day'", "interval '1 microsecond'", "interval '-1 microsecond'"] }.freeze
        FINEST = %w[0.000001 0.00001 0.0001 0.001 0.01 0.1 1].freeze

        def initialize(conn, constants)
          @conn = conn
          @constants = constants
          @categories = {}
        end

        def values(col)
          accepted = @constants.select { readable?(col, it) }
          accepted + accepted.flat_map { neighbours(col, it) }
        end

        def category(col) = @categories.fetch(col.oid) { @categories[col.oid] = ValuePools::Category.of(@conn, col) }

        private

        def readable?(col, value)
          @conn.exec_params("SELECT CAST($1 AS #{col.type})", [value])
          true
        rescue PG::Error
          false
        end

        def neighbours(col, value)
          steps = STEPS.fetch(category(col), []).filter_map do |step|
            sql = "SELECT (CAST($1 AS #{col.type}) OPERATOR(pg_catalog.+) #{step})::#{col.type}::pg_catalog.text"
            @conn.exec_params(sql, [value]).getvalue(0, 0)
          rescue PG::Error
            nil
          end
          category(col) == "N" ? steps + finest(col, value) : steps
        end

        # The value's nearest neighbour either side that col's type keeps.
        def finest(col, value)
          sql = fine_sql(col)
          %w[1 -1].filter_map do |sign|
            @conn.exec_params(sql, [value, sign, PG::TextEncoder::Array.new.encode(FINEST)]).values.dig(0, 0)
          rescue PG::Error
            nil
          end
        end

        # value + sign * step, as col's type, for the first step of FINEST
        # the type doesn't round away.
        def fine_sql(col)
          <<~SQL
            SELECT (CAST($1 AS #{col.type}) OPERATOR(pg_catalog.+)
                    ($2::pg_catalog.numeric OPERATOR(pg_catalog.*) p))::#{col.type}::pg_catalog.text
            FROM pg_catalog.unnest($3::pg_catalog.numeric[]) WITH ORDINALITY AS steps (p, n)
            WHERE (CAST($1 AS #{col.type}) OPERATOR(pg_catalog.+)
                   ($2::pg_catalog.numeric OPERATOR(pg_catalog.*) p))::#{col.type}
                  OPERATOR(pg_catalog.<>) CAST($1 AS #{col.type})
            ORDER BY n LIMIT 1
          SQL
        end
      end
    end
  end
end
