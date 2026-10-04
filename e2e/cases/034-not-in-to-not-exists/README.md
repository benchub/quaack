# Case 034: NOT IN over a NOT NULL column.

**Category:** `rewrite`, rewrite only.

**Exercises:** NOT IN subquery; anti-join rewrite; NOT NULL assumption checked in assumption-check.

## Setup.

60,000 `customers`, of whom the last 10,000 have no orders. Case 001's `orders`, with `customer_id` indexed.

## Slow query (`slow.sql`).

Gold APAC customers who never ordered. `NOT IN` can't become an anti-join, so Postgres hashes all 500,000 `customer_id`s to check about 600 customers.

## Expected result.

`NOT EXISTS`, which probes the index once per customer. Stated assumption: `orders.customer_id` is `NOT NULL`. With a NULL in the subquery, `NOT IN` returns nothing at all. Case 057 is the version where that assumption fails.

## Notes.

literals' worst-case set would use the top MCV, `tier = 'standard'` (48,000 customers). There the subquery is too big to hash in `work_mem`, so the original `NOT IN` rescans `orders` for every customer and runs for many minutes. QUAACK would meet that under run-discipline's `statement_timeout`. The set is left out here so the proof finishes.

## Proof.

`ruby e2e/verify.rb 034` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
