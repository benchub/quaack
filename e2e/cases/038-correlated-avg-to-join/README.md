# Case 038: Correlated average per row.

**Category:** `rewrite`, rewrite only.

**Exercises:** correlated scalar subquery in WHERE; pre-aggregate in a CTE and join; aggregate compared per group.

## Setup.

Case 001's `customers` and `orders`, with `customer_id` and `created_at` indexed.

## Slow query (`slow.sql`).

Recent orders above the customer's average. The subquery runs once per recent order, each time fetching all 10 of that customer's orders.

## Expected result.

Compute every customer's average once, then join. Both sides compare the same exact `numeric` averages, so the results match exactly.

## Notes.

For the "after the data" set, both versions touch only a few blocks: the planner sees that no recent orders exist and skips the aggregate.

## Proof.

`ruby e2e/verify.rb 038` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
