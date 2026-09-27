# Case 082: IS NOT TRUE to = false.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** IS NOT TRUE includes NULL; NULL fixtures (step 9, S2).

## Setup.

Case 081's `todos`. `archived` is NULL for 10% of rows.

## Slow query (`slow.sql`).

Count someone's unarchived todos.

## Expected result.

QUAACK must reject `archived = false`, which drops the rows where `archived` is NULL.

## Proof.

`ruby e2e/verify.rb 082` checks the claims above. The measured table is in `results.md`.
