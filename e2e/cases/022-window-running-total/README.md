# Case 022: Running total with a window function.

**Category:** `index`, new index only.

**Exercises:** window function with ORDER BY; sort removed by the index (5a-2); equality then ORDER BY columns (5a-1).

## Setup.

`ledger` has 500,000 rows for 1,000 accounts. Only the primary key is indexed.

## Slow query (`slow.sql`).

An account statement with a running balance. The whole ledger is scanned for 500 rows, which are then sorted.

## Expected result.

`ledger (account_id, posted_at, id)`. The rows arrive in window order, so no sort is needed.

## Proof.

`ruby e2e/verify.rb 022` checks the claims above. The measured table is in `results.md`.
