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

For the "after the data" set, the rewrite still aggregates the whole table, so it's worse there. By minimax (14b) QUAACK should reject this rewrite unless it finds a better one. See `results.md`.

## Proof.

`ruby e2e/verify.rb 038` checks the claims above. The measured table is in `results.md`.
