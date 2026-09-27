# Case 084: IS NOT DISTINCT FROM a constant.

**Category:** `rewrite`, rewrite only.

**Exercises:** IS NOT DISTINCT FROM; not indexable as written; literal isn't NULL assumption.

## Setup.

`issues` has 500,000 rows, and `team_id` is indexed and sometimes NULL.

## Slow query (`slow.sql`).

An ORM writes null-safe equality everywhere. Postgres can't use a btree index for `IS NOT DISTINCT FROM`.

## Expected result.

`team_id = 7`. Stated assumption: the literal isn't NULL. With a non-NULL literal, the two tests agree on every row, NULL rows included.

## Proof.

`ruby e2e/verify.rb 084` checks the claims above. The measured table is in `results.md`.
