# frozen_string_literal: true

module Quaack
  module Enclave
    module RewriteCandidateCheck
      # KeywordOperators' catalog query (20261011-12): a row if an operator
      # named in $1, in a schema in $2, has an argument type that's a
      # pseudo-type or one the candidate can reach. $3 holds its relations,
      # $4 its type names, and $5 and $6 the schemas and names of its
      # functions outside pg_catalog. A seen type brings in its domain's
      # base type and its array's element type, recursively, and reach adds
      # the types each seen type casts to implicitly.
      module KeywordReach
        SQL = <<~SQL
          WITH RECURSIVE seen(t) AS (
            SELECT a.atttypid FROM pg_catalog.pg_attribute a
            WHERE a.attrelid OPERATOR(pg_catalog.=) ANY (
                SELECT pg_catalog.to_regclass(r) FROM pg_catalog.unnest($3::pg_catalog.text[]) r)
              AND a.attnum OPERATOR(pg_catalog.>) 0
            UNION SELECT pg_catalog.to_regtype(n) FROM pg_catalog.unnest($4::pg_catalog.text[]) n
            UNION SELECT p.prorettype FROM pg_catalog.pg_proc p
              JOIN pg_catalog.pg_namespace pn ON pn.oid OPERATOR(pg_catalog.=) p.pronamespace
            WHERE EXISTS (
              SELECT 1 FROM ROWS FROM (pg_catalog.unnest($5::pg_catalog.text[]), pg_catalog.unnest($6::pg_catalog.text[])) f(s, n)
              WHERE f.s OPERATOR(pg_catalog.=) pn.nspname AND f.n OPERATOR(pg_catalog.=) p.proname)
            UNION SELECT x FROM pg_catalog.pg_type ty JOIN seen ON ty.oid OPERATOR(pg_catalog.=) seen.t,
              LATERAL (VALUES (ty.typbasetype), (ty.typelem)) v(x)
            WHERE x OPERATOR(pg_catalog.<>) 0
          ), reach(t) AS (
            SELECT t FROM seen
            UNION SELECT c.casttarget FROM pg_catalog.pg_cast c JOIN seen ON c.castsource OPERATOR(pg_catalog.=) seen.t
            WHERE c.castcontext OPERATOR(pg_catalog.=) 'i'
          )
          SELECT 1 FROM pg_catalog.pg_operator o
            JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) o.oprnamespace
          WHERE o.oprname OPERATOR(pg_catalog.=) ANY ($1::pg_catalog.text[])
            AND n.nspname OPERATOR(pg_catalog.=) ANY ($2::pg_catalog.text[])
            AND EXISTS (
              SELECT 1 FROM pg_catalog.pg_type a WHERE a.oid OPERATOR(pg_catalog.=) ANY (ARRAY[o.oprleft, o.oprright])
                AND (a.typtype OPERATOR(pg_catalog.=) 'p' OR a.oid OPERATOR(pg_catalog.=) ANY (SELECT t FROM reach)))
          LIMIT 1
        SQL
      end
    end
  end
end
