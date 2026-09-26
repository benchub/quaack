# Case 016: IS NULL on a high-cardinality column.

**Category:** `index`, new index only.

**Exercises:** IS NULL predicate atom; partial index dropped because its column isn't low-cardinality (5a-3); plain btree serves IS NULL.

## Setup.

`shipments` has 500,000 rows. `shipped_at` is NULL for 2,500 of them. Every other value is distinct.

## Slow query (`slow.sql`).

The oldest unshipped orders. The whole table is read to find the NULLs.

## Expected result.

A plain btree on `shipped_at`, which indexes NULLs. Postgres reads only the 2,500 NULL rows and sorts them. A partial index `WHERE shipped_at IS NULL` would be smaller, but 5a-3 must drop it: `shipped_at` has far more than 50 distinct values, so it isn't low-cardinality.

## Notes.

There's only one literal set because the query has no literals.

## Proof.

`ruby e2e/verify.rb 016` checks the claims above. The measured table is in `results.md`.
