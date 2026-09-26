# Case 028: MATERIALIZED CTE blocks predicate pushdown.

**Category:** `rewrite`, rewrite only.

**Exercises:** WITH ... AS MATERIALIZED; inline the CTE so the filter reaches the index.

## Setup.

Case 001's `customers` and `orders`, with `orders.customer_id` indexed.

## Slow query (`slow.sql`).

Someone wrapped the filter in a `MATERIALIZED` CTE, a habit from before Postgres 12. The fence stops `customer_id = 4242` from reaching the index, so Postgres materializes 300,000 rows and then filters them.

## Expected result.

Inline the CTE (or make it `NOT MATERIALIZED`). The index finds the customer's 10 orders directly.

## Proof.

`ruby e2e/verify.rb 028` checks the claims above. The measured table is in `results.md`.
