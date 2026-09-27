# Case 098: EXCEPT ALL to NOT EXISTS.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** EXCEPT ALL keeps multiplicities; duplicates fixture (step 9, S3).

## Setup.

Case 001's `customers` and `orders`. Each customer has about four orders since June, and one pending order.

## Slow query (`slow.sql`).

For each customer, one row per recent order, minus one per pending order.

## Expected result.

QUAACK must reject `NOT EXISTS`. `EXCEPT ALL` subtracts counts, so a customer with four recent orders and one pending keeps three rows. `NOT EXISTS` removes them all.

## Proof.

`ruby e2e/verify.rb 098` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
