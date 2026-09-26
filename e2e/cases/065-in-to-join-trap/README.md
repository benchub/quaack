# Case 065: IN (subquery) to a plain join.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** IN semi-join vs. join fan-out; duplicates fixture (step 9, S3); unmet uniqueness assumption (6b).

## Setup.

Case 001's `customers` and `orders`. Since October, most customers have ordered two or three times.

## Slow query (`slow.sql`).

Customers who ordered since October.

## Expected result.

QUAACK must reject the plain join. It returns a customer once per order since October, and `IN` returns each customer once. Stated assumption to watch for: "`orders.customer_id` is unique", which 6b rejects.

## Proof.

`ruby e2e/verify.rb 065` checks the claims above. The measured table is in `results.md`.
