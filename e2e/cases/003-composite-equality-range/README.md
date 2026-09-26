# Case 003: Equality plus a range, with only a one-column index.

**Category:** `index`, new index only.

**Exercises:** index scan whose Filter removes most rows (5a-2); equality column then one range column (5a-1); range literals as a BETWEEN-like pair (3e).

## Setup.

`events` has 500,000 rows for 1,000 accounts. Only `account_id` is indexed.

## Slow query (`slow.sql`).

An account's activity for one week. The index finds the account's 500 events, and a Filter throws away all but about 10 of them, each on its own heap page.

## Expected result.

`events (account_id, created_at)`: the equality column, then the range column. Only the week's rows are read.

## Proof.

`ruby e2e/verify.rb 003` checks the claims above. The measured table is in `results.md`.
