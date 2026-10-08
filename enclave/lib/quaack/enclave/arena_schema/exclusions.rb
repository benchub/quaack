# frozen_string_literal: true

require "json"

module Quaack
  module Enclave
    class ArenaSchema
      # A table's exclusion constraints, each as the names of its plain
      # columns compared with =, in key order. One with none is empty.
      module Exclusions
        # Each exclusion constraint's plain columns compared with =.
        SQL = <<~SQL
          SELECT pg_catalog.array_to_json(ARRAY(
                   SELECT a.attname
                   FROM ROWS FROM (pg_catalog.unnest(c.conkey), pg_catalog.unnest(c.conexclop)) WITH ORDINALITY k(n, op, o)
                   JOIN pg_catalog.pg_operator p ON p.oid OPERATOR(pg_catalog.=) k.op
                   JOIN pg_catalog.pg_attribute a
                     ON a.attrelid OPERATOR(pg_catalog.=) c.conrelid AND a.attnum OPERATOR(pg_catalog.=) k.n
                   WHERE p.oprname OPERATOR(pg_catalog.=) '='
                   ORDER BY k.o))
          FROM pg_catalog.pg_constraint c
          WHERE c.conrelid OPERATOR(pg_catalog.=) $1::pg_catalog.regclass AND c.contype OPERATOR(pg_catalog.=) 'x'
          ORDER BY c.conname
        SQL

        # found (UniqueIndexes' hash) with each exclusion constraint's =
        # columns added to its uniques, and unequal_exclusion.
        def self.add(conn, regclass, found)
          equal, unequal = conn.exec_params(SQL, [regclass]).column_values(0).map { JSON.parse(it) }.partition(&:any?)
          found.merge(uniques: found[:uniques] + equal, unequal_exclusion: unequal.any?)
        end
      end
    end
  end
end
