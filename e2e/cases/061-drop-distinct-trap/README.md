# Case 061: Dropping DISTINCT over a fan-out join.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** DISTINCT removed on a false uniqueness claim; unmet uniqueness assumption (assumption-check); duplicates fixture (rewrite-test, S3).

## Setup.

Case 001's `customers` and `orders`.

## Slow query (`slow.sql`).

Which regions ordered recently.

## Expected result.

QUAACK must reject dropping `DISTINCT`: every recent order repeats its region. An LLM that claims `region` is unique per row fails assumption-check, and rewrite-test's S3 scenario disproves an operator's version.

## Proof.

`ruby e2e/verify.rb 061` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
