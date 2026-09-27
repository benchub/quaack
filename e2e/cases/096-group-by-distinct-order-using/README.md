# Case 096: GROUP BY DISTINCT and ORDER BY USING.

**Category:** `index`, new index only.

**Exercises:** GROUP BY DISTINCT; ORDER BY ... USING operator; ORDER BY an aggregate alias.

## Setup.

`tickets` has 500,000 rows for 200 tenants. Only the primary key is indexed.

## Slow query (`slow.sql`).

A tenant's status counts, largest first. It's written with `GROUP BY DISTINCT` and `ORDER BY ... USING >`.

## Expected result.

`tickets (tenant_id, status)`, for an index-only scan that comes out grouped.

## Proof.

`ruby e2e/verify.rb 096` checks the claims above. The measured table is in `results.md`.
