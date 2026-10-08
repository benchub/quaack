# frozen_string_literal: true

module Quaack
  module Enclave
    module AssumptionCheck
      # Whether a unique index i compares each of its key columns as the
      # column's own = does, so that "no two rows are equal in these
      # columns" holds by that =. It must use the type's default operator
      # class, since another, such as record_image_ops, may compare more
      # finely. And it must use the column's collation, unless both are
      # deterministic, whose = is byte equality: an index COLLATE "C" on a
      # case-blind column lets in both 'Ann' and 'ann'. A condition on
      # pg_index i, for UNIQUE.
      module IndexEquality
        SQL = <<~SQL
          NOT EXISTS (
            SELECT 1 FROM ROWS FROM (pg_catalog.unnest(i.indkey::pg_catalog.int2[]),
                                     pg_catalog.unnest(i.indclass::pg_catalog.oid[]),
                                     pg_catalog.unnest(i.indcollation::pg_catalog.oid[])) WITH ORDINALITY AS u(k, cls, coll, n)
            JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) i.indrelid AND a.attnum OPERATOR(pg_catalog.=) u.k
            JOIN pg_catalog.pg_opclass oc ON oc.oid OPERATOR(pg_catalog.=) u.cls
            LEFT JOIN pg_catalog.pg_collation ic ON ic.oid OPERATOR(pg_catalog.=) u.coll
            LEFT JOIN pg_catalog.pg_collation ac ON ac.oid OPERATOR(pg_catalog.=) a.attcollation
            WHERE u.n OPERATOR(pg_catalog.<=) i.indnkeyatts
              AND (NOT oc.opcdefault
                   OR (u.coll OPERATOR(pg_catalog.<>) a.attcollation
                       AND NOT (COALESCE(ic.collisdeterministic, true) AND COALESCE(ac.collisdeterministic, true)))))
        SQL
      end
    end
  end
end
