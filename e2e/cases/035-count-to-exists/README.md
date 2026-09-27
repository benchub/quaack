# Case 035: count(*) > 0 instead of EXISTS.

**Category:** `rewrite`, rewrite only.

**Exercises:** correlated scalar subquery; EXISTS stops at the first match.

## Setup.

Case 001's `customers` and `orders`, with `orders.customer_id` indexed. Each customer has 8 shipped orders.

## Slow query (`slow.sql`).

Gold customers with a shipped order. Counting reads all 10 orders per customer, when the first shipped one settles it.

## Expected result.

`EXISTS`, which can stop at the first match. The planner turns it into a semi-join.

## Proof.

`ruby e2e/verify.rb 035` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
