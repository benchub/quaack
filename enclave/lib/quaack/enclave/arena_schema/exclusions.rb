# frozen_string_literal: true

require "json"

module Quaack
  module Enclave
    class ArenaSchema
      # A table's exclusion constraints. One with plain columns compared
      # with pg_catalog's btree equality counts as a unique key over them.
      # One with none, no WHERE predicate, and only plain columns compared
      # with pg_catalog's && on a range whose subtype Values steps through
      # soundly (STEPPED) counts as a unique key over those columns:
      # Values#nth gives each row the range holding just its own nth
      # subtype value, so no two rows overlap. Any other (a multirange, an
      # expression, another operator) makes unequal_exclusion.
      module Exclusions
        STEPPED = %w[int4 int8 numeric date timestamp timestamptz].freeze

        # Each element as [column or NULL, btree equality?, steppable
        # overlap with no constraint predicate?].
        SQL = <<~SQL
          SELECT pg_catalog.array_to_json(ARRAY(
                   SELECT pg_catalog.json_build_array(a.attname,
                     p.oprnamespace OPERATOR(pg_catalog.=) 'pg_catalog'::pg_catalog.regnamespace AND EXISTS (
                       SELECT FROM pg_catalog.pg_amop o
                       JOIN pg_catalog.pg_am m ON m.oid OPERATOR(pg_catalog.=) o.amopmethod
                       WHERE o.amopopr OPERATOR(pg_catalog.=) p.oid AND m.amname OPERATOR(pg_catalog.=) 'btree'
                         AND o.amopstrategy OPERATOR(pg_catalog.=) 3),
                     p.oprnamespace OPERATOR(pg_catalog.=) 'pg_catalog'::pg_catalog.regnamespace
                       AND p.oprname OPERATOR(pg_catalog.=) '&&'
                       AND sn.nspname OPERATOR(pg_catalog.=) 'pg_catalog'
                       AND st.typname OPERATOR(pg_catalog.=) ANY ($2::pg_catalog.name[]) AND i.indpred IS NULL)
                   FROM ROWS FROM (pg_catalog.unnest(c.conkey), pg_catalog.unnest(c.conexclop)) WITH ORDINALITY k(n, op, o)
                   JOIN pg_catalog.pg_operator p ON p.oid OPERATOR(pg_catalog.=) k.op
                   LEFT JOIN pg_catalog.pg_attribute a
                     ON a.attrelid OPERATOR(pg_catalog.=) c.conrelid AND a.attnum OPERATOR(pg_catalog.=) k.n
                   LEFT JOIN pg_catalog.pg_range r ON r.rngtypid OPERATOR(pg_catalog.=) a.atttypid
                   LEFT JOIN pg_catalog.pg_type st ON st.oid OPERATOR(pg_catalog.=) r.rngsubtype
                   LEFT JOIN pg_catalog.pg_namespace sn ON sn.oid OPERATOR(pg_catalog.=) st.typnamespace
                   ORDER BY k.o))
          FROM pg_catalog.pg_constraint c
          JOIN pg_catalog.pg_index i ON i.indexrelid OPERATOR(pg_catalog.=) c.conindid
          WHERE c.conrelid OPERATOR(pg_catalog.=) $1::pg_catalog.regclass AND c.contype OPERATOR(pg_catalog.=) 'x'
          ORDER BY c.conname
        SQL

        # found (UniqueIndexes' hash) with each exclusion constraint's key
        # added to its uniques, and unequal_exclusion.
        def self.add(conn, regclass, found)
          rows = conn.exec_params(SQL, [regclass, "{#{STEPPED.join(",")}}"]).column_values(0)
          keys = rows.map { key(JSON.parse(it)) }
          found.merge(uniques: found[:uniques] + keys.compact, unequal_exclusion: keys.include?(nil))
        end

        # The constraint's key, or nil when rewrite-test can't keep its
        # rows apart.
        def self.key(elements)
          equal = elements.filter_map { |col, eq, _| col if eq }
          return equal if equal.any?

          elements.map(&:first) if elements.all? { |_, _, overlap| overlap }
        end
      end
    end
  end
end
