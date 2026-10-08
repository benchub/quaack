# frozen_string_literal: true

module Quaack
  module Enclave
    module AssumptionCheck
      # Whether a unique index i compares each of its key columns as the
      # column's own = does, so that "no two rows are equal in these
      # columns" holds by that =. Its operator class must be the type's
      # default, or a btree class whose = (strategy 3) is the default
      # class's, as text_pattern_ops's is: another, such as
      # record_image_ops, may compare more finely. And it must use the
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

        # Class oc has an =, and every default class of its type and
        # method, of which there must be one, has that same =.
        SAME_EQUALITY = <<~SQL.chomp
          (#{equality("oc")} IS NOT NULL
           AND EXISTS (SELECT 1 FROM pg_catalog.pg_opclass d
                       WHERE d.opcmethod #{EQ} oc.opcmethod AND d.opcintype #{EQ} oc.opcintype AND d.opcdefault)
           AND NOT EXISTS (
             SELECT 1 FROM pg_catalog.pg_opclass d
             WHERE d.opcmethod #{EQ} oc.opcmethod AND d.opcintype #{EQ} oc.opcintype AND d.opcdefault
               AND NOT COALESCE(#{equality("d")} #{EQ} #{equality("oc")}, false)))
        SQL

        SQL = <<~SQL.freeze
          NOT EXISTS (
            SELECT 1 FROM ROWS FROM (pg_catalog.unnest(i.indkey::pg_catalog.int2[]),
                                     pg_catalog.unnest(i.indclass::pg_catalog.oid[]),
                                     pg_catalog.unnest(i.indcollation::pg_catalog.oid[])) WITH ORDINALITY AS u(k, cls, coll, n)
            JOIN pg_catalog.pg_attribute a ON a.attrelid #{EQ} i.indrelid AND a.attnum #{EQ} u.k
            JOIN pg_catalog.pg_opclass oc ON oc.oid #{EQ} u.cls
            LEFT JOIN pg_catalog.pg_collation ic ON ic.oid #{EQ} u.coll
            LEFT JOIN pg_catalog.pg_collation ac ON ac.oid #{EQ} a.attcollation
            WHERE u.n OPERATOR(pg_catalog.<=) i.indnkeyatts
              AND (NOT (oc.opcdefault OR #{SAME_EQUALITY})
                   OR (u.coll OPERATOR(pg_catalog.<>) a.attcollation
                       AND NOT (COALESCE(ic.collisdeterministic, true) AND COALESCE(ac.collisdeterministic, true)))))
        SQL
      end
    end
  end
end
