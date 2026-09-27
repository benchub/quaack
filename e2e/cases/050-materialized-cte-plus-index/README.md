# Case 050: MATERIALIZED CTE over an unindexed column.

**Category:** `both`, rewrite + new index.

**Exercises:** WITH ... AS MATERIALIZED; index that only helps once the fence is gone.

## Setup.

`events` has 500,000 rows for 1,000 accounts. Only the primary key is indexed.

## Slow query (`slow.sql`).

One account's purchases, through a `MATERIALIZED` CTE.

## Expected result.

Inline the CTE, and add `events (account_id, kind)`. The fence stops the index from helping the original, and without the index the inlined query still scans the table.

## Proof.

`ruby e2e/verify.rb 050` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
