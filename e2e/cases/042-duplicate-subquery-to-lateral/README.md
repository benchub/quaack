# Case 042: The same correlated subquery twice.

**Category:** `rewrite`, rewrite only.

**Exercises:** correlated scalar subquery in SELECT and WHERE; LATERAL computes it once; aggregate over an empty set is NULL.

## Setup.

Case 001's `customers` and `orders`, with only `orders.customer_id` indexed.

## Slow query (`slow.sql`).

Gold customers who haven't ordered lately. The same subquery runs in the `WHERE` and again in the select list, each time reading all 10 of the customer's orders.

## Expected result.

Compute it once in a `LATERAL` subquery. For a customer with no orders, `max` returns NULL in both versions, so the filter drops them either way.

## Proof.

`ruby e2e/verify.rb 042` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
