# Case 058: UNION to UNION ALL when the branches overlap.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** UNION ALL keeps duplicates; overlapping branches; fixtures with a row that matches both (rewrite-test, S1).

## Setup.

Case 001's `customers` and `orders`, with `customer_id` and `created_at` indexed. Customer 5001's latest order is from 10 December.

## Slow query (`slow.sql`).

A customer's orders plus everyone's recent orders. `UNION` sorts or hashes to remove duplicates, which looks like wasted work.

## Expected result.

QUAACK must reject `UNION ALL`. An order that's both the customer's and recent comes back twice. Stated assumption to watch for: "the branches are disjoint", which no constraint supports.

## Proof.

`ruby e2e/verify.rb 058` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
