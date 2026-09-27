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
          JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
          WHERE n.nspname = ANY ($1::text[]) AND t.typname = $2
        ), target (named, oid) AS (
          SELECT oid, oid FROM named
          UNION
          SELECT target.named, t.typbasetype
          FROM target JOIN pg_catalog.pg_type t ON t.oid = target.oid
          WHERE t.typbasetype <> 0
        ), called (named, oid) AS (
          SELECT target.named, c.castfunc
          FROM target
          JOIN pg_catalog.pg_type t ON t.oid = target.oid
          JOIN pg_catalog.pg_cast c ON c.casttarget IN (t.oid, t.typarray)
          UNION ALL
          SELECT target.named, t.typinput::oid
          FROM target JOIN pg_catalog.pg_type t ON t.oid = target.oid
          UNION ALL
          SELECT target.named, d.refobjid
          FROM target
          JOIN pg_catalog.pg_constraint con ON con.contypid = target.oid
          JOIN pg_catalog.pg_depend d ON d.classid = 'pg_catalog.pg_constraint'::pg_catalog.regclass
            AND d.objid = con.oid AND d.refclassid = 'pg_catalog.pg_proc'::pg_catalog.regclass
        )
        SELECT pg_catalog.quote_ident(named.nspname), pg_catalog.quote_ident(named.typname),
               pg_catalog.quote_ident(fn.nspname), pg_catalog.quote_ident(f.proname)
        FROM called
        JOIN named ON named.oid = called.named
        JOIN pg_catalog.pg_proc f ON f.oid = called.oid
        JOIN pg_catalog.pg_namespace fn ON fn.oid = f.pronamespace
        WHERE f.provolatile = 'v'
        ORDER BY pg_catalog.array_position($1::text[], named.nspname::text), named.oid, f.oid
        LIMIT 1
      SQL
    end
  end
end
