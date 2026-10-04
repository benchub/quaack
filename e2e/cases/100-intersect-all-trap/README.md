# Case 100: INTERSECT ALL to INTERSECT.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** INTERSECT ALL keeps multiplicities; duplicates fixture (rewrite-test, S3).

## Setup.

Case 001's `customers` and `orders`. Each customer has about five orders in each half of the year.

## Slow query (`slow.sql`).

One row per order a customer could pair across the two halves of the year.

## Expected result.

QUAACK must reject plain `INTERSECT`, which returns each customer once instead of min(first half, second half) times.

## Proof.

`ruby e2e/verify.rb 100` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
