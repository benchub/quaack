# Case 029: CTE referenced twice gets materialized.

**Category:** `rewrite`, rewrite only.

**Exercises:** CTE referenced more than once; UNION ALL; NOT MATERIALIZED.

## Setup.

Case 001's `customers` and `orders`, with `orders.customer_id` indexed.

## Slow query (`slow.sql`).

Two customers' totals from one CTE. Postgres 12+ materializes a CTE that's referenced twice, so the whole `orders` table is copied before either filter applies.

## Expected result.

`NOT MATERIALIZED` (or inlining it). Each branch then uses the index.

## Proof.

`ruby e2e/verify.rb 029` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
