# frozen_string_literal: true

module Quaack
  module Enclave
    class ArenaSchema
      # The columns a table's generated columns' expressions read, from
      # pg_depend.
      module GenerationInputs
        SQL = <<~SQL
          SELECT DISTINCT a.attname
          FROM pg_catalog.pg_attrdef d
          JOIN pg_catalog.pg_attribute g
            ON g.attrelid OPERATOR(pg_catalog.=) d.adrelid AND g.attnum OPERATOR(pg_catalog.=) d.adnum
          JOIN pg_catalog.pg_depend p
            ON p.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_attrdef'::pg_catalog.regclass
           AND p.objid OPERATOR(pg_catalog.=) d.oid
           AND p.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
           AND p.refobjid OPERATOR(pg_catalog.=) d.adrelid AND p.refobjsubid OPERATOR(pg_catalog.>) 0
           AND p.refobjsubid OPERATOR(pg_catalog.<>) d.adnum
          JOIN pg_catalog.pg_attribute a
            ON a.attrelid OPERATOR(pg_catalog.=) d.adrelid AND a.attnum OPERATOR(pg_catalog.=) p.refobjsubid
          WHERE d.adrelid OPERATOR(pg_catalog.=) $1::pg_catalog.regclass AND g.attgenerated OPERATOR(pg_catalog.<>) ''
          ORDER BY 1
        SQL

        def self.read(conn, regclass) = conn.exec_params(SQL, [regclass]).column_values(0)
      end
    end
  end
end
