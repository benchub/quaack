# Case 034: NOT IN over a NOT NULL column.

**Category:** `rewrite`, rewrite only.

**Exercises:** NOT IN subquery; anti-join rewrite; NOT NULL assumption checked in 6b.

## Setup.

60,000 `customers`, of whom the last 10,000 have no orders. Case 001's `orders`, with `customer_id` indexed.

## Slow query (`slow.sql`).

Gold APAC customers who never ordered. `NOT IN` can't become an anti-join, so Postgres hashes all 500,000 `customer_id`s to check about 600 customers.

## Expected result.

`NOT EXISTS`, which probes the index once per customer. Stated assumption: `orders.customer_id` is `NOT NULL`. With a NULL in the subquery, `NOT IN` returns nothing at all. Case 059 is the version where that assumption fails.

## Proof.

`ruby e2e/verify.rb 034` checks the claims above. The measured table is in `results.md`.
