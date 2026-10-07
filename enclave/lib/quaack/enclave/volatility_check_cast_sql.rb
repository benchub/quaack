# frozen_string_literal: true

module Quaack
  module Enclave
    # VolatilityCheck's catalog query for casts, in its own file for length.
    module VolatilityCheck
      # A domain's base type can be another domain, so the base types are
      # followed all the way down.
      CAST_SQL = <<~SQL
        WITH RECURSIVE named AS (
          SELECT t.oid, n.nspname, t.typname
          FROM pg_catalog.pg_type t
          JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) t.typnamespace
          WHERE n.nspname OPERATOR(pg_catalog.=) ANY ($1::pg_catalog.text[]) AND t.typname OPERATOR(pg_catalog.=) $2
        ), target (named, oid) AS (
          SELECT oid, oid FROM named
          UNION
          SELECT target.named, t.typbasetype
          FROM target JOIN pg_catalog.pg_type t ON t.oid OPERATOR(pg_catalog.=) target.oid
          WHERE t.typbasetype OPERATOR(pg_catalog.<>) 0
        ), called (named, oid) AS (
          SELECT target.named, c.castfunc
          FROM target
          JOIN pg_catalog.pg_type t ON t.oid OPERATOR(pg_catalog.=) target.oid
          JOIN pg_catalog.pg_cast c ON c.casttarget OPERATOR(pg_catalog.=) ANY (ARRAY[t.oid, t.typarray])
          UNION ALL
          SELECT target.named, t.typinput::pg_catalog.oid
          FROM target JOIN pg_catalog.pg_type t ON t.oid OPERATOR(pg_catalog.=) target.oid
          UNION ALL
          SELECT target.named, d.refobjid
          FROM target
          JOIN pg_catalog.pg_constraint con ON con.contypid OPERATOR(pg_catalog.=) target.oid
          JOIN pg_catalog.pg_depend d ON d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_constraint'::pg_catalog.regclass
            AND d.objid OPERATOR(pg_catalog.=) con.oid
            AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_proc'::pg_catalog.regclass
        )
        SELECT pg_catalog.quote_ident(named.nspname), pg_catalog.quote_ident(named.typname),
               pg_catalog.quote_ident(fn.nspname), pg_catalog.quote_ident(f.proname)
        FROM called
        JOIN named ON named.oid OPERATOR(pg_catalog.=) called.named
        JOIN pg_catalog.pg_proc f ON f.oid OPERATOR(pg_catalog.=) called.oid
        JOIN pg_catalog.pg_namespace fn ON fn.oid OPERATOR(pg_catalog.=) f.pronamespace
        WHERE f.provolatile OPERATOR(pg_catalog.=) 'v'
        ORDER BY pg_catalog.array_position($1::pg_catalog.text[], named.nspname::pg_catalog.text), named.oid, f.oid
        LIMIT 1
      SQL
    end
  end
end
