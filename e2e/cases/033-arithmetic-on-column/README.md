# Case 033: Integer division on an indexed column.

**Category:** `rewrite`, rewrite only.

**Exercises:** arithmetic on the column; CHECK constraint as a stated assumption (6b); simple CHECK accepted by fixtures (step 9).

## Setup.

`charges` has 500,000 rows with `amount_cents` from 0 to 99,999, indexed, and `CHECK (amount_cents >= 0)`.

## Slow query (`slow.sql`).

Charges in one whole-dollar bucket. Dividing the column hides it from the index.

## Expected result.

A half-open range on `amount_cents`. Stated assumption: `amount_cents >= 0`. Integer division truncates toward zero, so without it, -99 would land in bucket 0. 6b finds the `CHECK` in `pg_constraint`.

## Proof.

`ruby e2e/verify.rb 033` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
