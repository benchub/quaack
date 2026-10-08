# frozen_string_literal: true

module Quaack
  module Enclave
    class ArenaSchema
      # Whether constraint c, a CHECK, uses an operator outside pg_catalog
      # that no extension owns, such as citext's, as the catalog records it
      # (task 20261007-41): an SQL boolean for CONSTRAINTS_SQL and
      # DomainChecks::QUERY. pg_get_constraintdef prints an operator bare
      # whenever the search_path finds it first, so its text can't tell.
      FOREIGN_OPERATOR_SQL = <<~SQL.chomp
        EXISTS (
          SELECT 1 FROM pg_catalog.pg_depend d
          JOIN pg_catalog.pg_operator o ON o.oid OPERATOR(pg_catalog.=) d.refobjid
          WHERE d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_constraint'::pg_catalog.regclass
            AND d.objid OPERATOR(pg_catalog.=) c.oid
            AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_operator'::pg_catalog.regclass
            AND o.oprnamespace OPERATOR(pg_catalog.<>) 'pg_catalog'::pg_catalog.regnamespace
            AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend e
              WHERE e.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_operator'::pg_catalog.regclass
                AND e.objid OPERATOR(pg_catalog.=) o.oid
                AND e.deptype OPERATOR(pg_catalog.=) 'e'::pg_catalog."char"))
      SQL
    end
  end
end
