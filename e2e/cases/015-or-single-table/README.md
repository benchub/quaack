# Case 015: OR on two columns of one table, one unindexed.

**Category:** `index`, new index only.

**Exercises:** OR within one table; BitmapOr becomes possible once both columns are indexed; no rewrite needed.

## Setup.

`accounts` has 400,000 rows. `email` is unique; `phone` has no index, and a quarter of the phones are NULL.

## Slow query (`slow.sql`).

Look someone up by email or phone. One unindexed side of the `OR` forces a full scan.

## Expected result.

`accounts (phone)`. Then Postgres ORs two bitmap index scans. Unlike case 001, both columns are in one table, so no rewrite is needed.

## Proof.

`ruby e2e/verify.rb 015` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
