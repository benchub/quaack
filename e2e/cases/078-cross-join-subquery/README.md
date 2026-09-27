# Case 078: CROSS JOIN to an aggregate subquery.

**Category:** `index`, new index only.

**Exercises:** CROSS JOIN; subquery in FROM; max() that an index can answer.

## Setup.

Case 001's `customers` and `orders`, with no index on `created_at`.

## Slow query (`slow.sql`).

Orders from the last hour of data. Without an index, Postgres scans the table once for `max` and again for the filter.

## Expected result.

`orders (created_at)`: `max` reads one index entry, and the filter becomes a short range scan.

## Proof.

`ruby e2e/verify.rb 078` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
