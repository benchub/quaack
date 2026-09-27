# Case 052: Correlated running sum with no index.

**Category:** `both`, rewrite + new index.

**Exercises:** correlated subquery per row; window function rewrite; composite index for the window order.

## Setup.

`ledger` has 500,000 rows for 5,000 accounts. Only the primary key and `posted_at` are indexed.

## Slow query (`slow.sql`).

A running balance through a correlated subquery, with no index on `account_id`. Every row's subquery scans the table.

## Expected result.

The window rewrite from case 040, plus `ledger (account_id, posted_at)`. The rewrite alone scans the table once, and the index alone still runs 100 subqueries.

## Proof.

`ruby e2e/verify.rb 052` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
