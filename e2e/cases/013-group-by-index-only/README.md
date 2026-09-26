# Case 013: Status counts for one tenant.

**Category:** `index`, new index only.

**Exercises:** Sort or Hash feeding an aggregate (5a-2); GROUP BY columns after the equality column (5a-1); index-only scan.

## Setup.

`tickets` has 500,000 rows for 200 tenants. `tenant_id` is indexed.

## Slow query (`slow.sql`).

A tenant's dashboard counts. The index finds 2,500 rows, and each costs a heap fetch.

## Expected result.

`tickets (tenant_id, status)`: the equality column, then the `GROUP BY` column. It's an index-only scan that comes out grouped.

## Proof.

`ruby e2e/verify.rb 013` checks the claims above. The measured table is in `results.md`.
