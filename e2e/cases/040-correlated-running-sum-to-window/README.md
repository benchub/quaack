# Case 040: Running balance with a correlated subquery.

**Category:** `rewrite`, rewrite only.

**Exercises:** correlated subquery per row; window function rewrite; unique ORDER BY key assumption (assumption-check).

## Setup.

`ledger` has 500,000 rows for 1,000 accounts, indexed on `(account_id, posted_at)`. `posted_at` is unique.

## Slow query (`slow.sql`).

An account statement with a running balance. For each of 500 rows, the subquery re-reads every earlier row of the account.

## Expected result.

`sum(amount) OVER (ORDER BY posted_at)`. Stated assumption: `posted_at` is unique. With ties, the default `RANGE` frame and the `<=` subquery both include peers, so they'd still agree, but the unique constraint makes it plain.

## Proof.

`ruby e2e/verify.rb 040` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
