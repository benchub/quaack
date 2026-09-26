# Case 062: count(column) to count(*).

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** count of a nullable column; NULL fixtures (step 9, S2).

## Setup.

Case 001's `customers` and `orders`. Pending and cancelled orders have no tracking number.

## Slow query (`slow.sql`).

How many of a customer's orders have tracking.

## Expected result.

QUAACK must reject `count(*)`, which also counts orders whose `tracking_number` is NULL.

## Proof.

`ruby e2e/verify.rb 062` checks the claims above. The measured table is in `results.md`.
