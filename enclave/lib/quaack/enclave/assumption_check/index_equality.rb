# frozen_string_literal: true

module Quaack
  module Enclave
    module AssumptionCheck
      # Whether a unique index i compares each of its key columns as the
      # column's own = does, so that "no two rows are equal in these
      # columns" holds by that =. Its operator class must be a btree class
      # whose = (strategy 3) is the column's type's default class's, as
      # text_pattern_ops's is on text: another, such as record_image_ops,
      # or text_ops on citext, may compare more finely. And it must use the
      # column's collation, unless both are deterministic, whose = is byte
      # equality: an index COLLATE "C" on a case-blind column lets in both
      # 'Ann' and 'ann'. A condition on pg_index i, for UNIQUE.
      module IndexEquality
        EQ = "OPERATOR(pg_catalog.=)"

        # The = of the operator class aliased opclass, if it's a btree class that has one.
        def self.equality(opclass)
          <<~SQL.chomp
            (SELECT o.amopopr FROM pg_catalog.pg_amop o
             WHERE o.amopfamily #{EQ} #{opclass}.opcfamily AND o.amoplefttype #{EQ} #{opclass}.opcintype
               AND o.amoprighttype #{EQ} #{opclass}.opcintype AND o.amopstrategy #{EQ} 3
               AND o.amopmethod #{EQ} #{opclass}.opcmethod
               AND o.amopmethod #{EQ} (SELECT am.oid FROM pg_catalog.pg_am am WHERE am.amname #{EQ} 'btree'))
          SQL
        end
        private_class_method :equality

        # The type of column a, or for a domain its base type's.
        BASE_TYPE = <<~SQL.chomp
          (WITH RECURSIVE ty(oid, base, kind) AS (
             SELECT t.oid, t.typbasetype, t.typtype FROM pg_catalog.pg_type t WHERE t.oid #{EQ} a.atttypid
             UNION ALL
             SELECT t.oid, t.typbasetype, t.typtype FROM pg_catalog.pg_type t JOIN ty ON t.oid #{EQ} ty.base
             WHERE ty.kind #{EQ} 'd')
           SELECT ty.oid FROM ty WHERE ty.kind OPERATOR(pg_catalog.<>) 'd')
        SQL

        # The type whose default classes give the column's =: the column's
        # own, if it has a default class for oc's method, else oc's input
        # type, as varchar takes text's.
        OWN_TYPE = <<~SQL.chomp
          (SELECT COALESCE((SELECT d.opcintype FROM pg_catalog.pg_opclass d
                            WHERE d.opcmethod #{EQ} oc.opcmethod AND d.opcdefault AND d.opcintype #{EQ} bt.base
                            LIMIT 1), oc.opcintype))
        SQL

        # Class oc has an =, and every default class of the column's type
        # and oc's method, of which there must be one, has that same =.
        SAME_EQUALITY = <<~SQL.chomp
          (#{equality("oc")} IS NOT NULL
           AND EXISTS (SELECT 1 FROM pg_catalog.pg_opclass d
                       WHERE d.opcmethod #{EQ} oc.opcmethod AND d.opcintype #{EQ} own.intype AND d.opcdefault)
           AND NOT EXISTS (
             SELECT 1 FROM pg_catalog.pg_opclass d
             WHERE d.opcmethod #{EQ} oc.opcmethod AND d.opcintype #{EQ} own.intype AND d.opcdefault
               AND NOT COALESCE(#{equality("d")} #{EQ} #{equality("oc")}, false)))
        SQL

        SQL = <<~SQL.freeze
          NOT EXISTS (
            SELECT 1 FROM ROWS FROM (pg_catalog.unnest(i.indkey::pg_catalog.int2[]),
                                     pg_catalog.unnest(i.indclass::pg_catalog.oid[]),
                                     pg_catalog.unnest(i.indcollation::pg_catalog.oid[])) WITH ORDINALITY AS u(k, cls, coll, n)
            JOIN pg_catalog.pg_attribute a ON a.attrelid #{EQ} i.indrelid AND a.attnum #{EQ} u.k
            JOIN pg_catalog.pg_opclass oc ON oc.oid #{EQ} u.cls
            CROSS JOIN LATERAL (SELECT #{BASE_TYPE} AS base) bt
            CROSS JOIN LATERAL (SELECT #{OWN_TYPE} AS intype) own
            LEFT JOIN pg_catalog.pg_collation ic ON ic.oid #{EQ} u.coll
            LEFT JOIN pg_catalog.pg_collation ac ON ac.oid #{EQ} a.attcollation
            WHERE u.n OPERATOR(pg_catalog.<=) i.indnkeyatts
              AND (NOT #{SAME_EQUALITY}
                   OR (u.coll OPERATOR(pg_catalog.<>) a.attcollation
                       AND NOT (COALESCE(ic.collisdeterministic, true) AND COALESCE(ac.collisdeterministic, true)))))
        SQL
      end
    end
  end
end
