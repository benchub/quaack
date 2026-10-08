# frozen_string_literal: true

require_relative "../../assumption_check"

module Quaack
  module Enclave
    module RewriteRules
      class Catalog
        # For a rule that needs a key among some of a table's columns, the
        # column sets that may be one, in one read of the table's indexes:
        #
        #   catalog.keys("public", "pairs")   # => [["x", "y"]]
        #
        # Each is the key columns of a unique index, in index order, the
        # indexes in the order they were made; an expression is left out.
        # They're only candidates: whether one is a key, unique and not
        # null, is the unique and not_null assumptions' to say, through met?,
        # which refuses a partial or expression index. A table that doesn't
        # exist has none.
        module Keys
          EQ = "OPERATOR(pg_catalog.=)"

          KEYS = <<~SQL.freeze
            SELECT i.indexrelid, a.attname
            FROM pg_catalog.pg_index i
            CROSS JOIN LATERAL pg_catalog.unnest(i.indkey::pg_catalog.int2[]) WITH ORDINALITY AS u(k, n)
            JOIN pg_catalog.pg_attribute a ON a.attrelid #{EQ} i.indrelid AND a.attnum #{EQ} u.k
            WHERE i.indrelid #{EQ} #{AssumptionCheck::RELATION} AND i.indisunique
              AND u.n OPERATOR(pg_catalog.<=) i.indnkeyatts
            ORDER BY i.indexrelid, u.n
          SQL

          def keys(schema, table)
            (@keys ||= {})[[schema, table]] ||=
              @connection.exec_params(KEYS, [schema, table]).values.chunk_while { |a, b| a.first == b.first }
                         .map { |rows| rows.map(&:last) }
          end
        end
      end
    end
  end
end
