# Case 080: Named window with a ROWS frame.

**Category:** `index`, new index only.

**Exercises:** WINDOW clause; window referenced by name; ROWS BETWEEN frame.

## Setup.

Case 040's `ledger`, with only the primary key and unique `posted_at` indexed.

## Slow query (`slow.sql`).

A seven-entry moving average and sum for one account. The whole ledger is scanned.

## Expected result.

`ledger (account_id, posted_at)`. Rows arrive in window order.

## Proof.

`ruby e2e/verify.rb 080` checks the claims above. The measured table is in `results.md`.
