# Case 025: Nested loop whose inner side over-fetches.

**Category:** `index`, new index only.

**Exercises:** Nested Loop with an expensive inner side (index-from-plan); inner join key plus its filter column; low-cardinality filter.

## Setup.

Case 001's `customers` and `orders`. 500 customers are gold in APAC, and each customer has exactly one pending order. `orders.customer_id` is indexed.

## Slow query (`slow.sql`).

Pending orders of gold APAC customers. The nested loop's inner index scan fetches all 10 orders per customer, then filters out 90%.

## Expected result.

`orders (customer_id, status)`: the join key plus the inner filter column.

## Proof.

`ruby e2e/verify.rb 025` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
