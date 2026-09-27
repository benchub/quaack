# Case 012: Join to a child table with no index on its foreign key.

**Category:** `index`, new index only.

**Exercises:** Hash Join with a large inner build (5a-2); join condition columns (5a-1); three tables.

## Setup.

Case 001's `customers` and `orders`, plus 2,000 `products` and 1.5 million `order_items` (three per order). `order_items.order_id` has no index.

## Slow query (`slow.sql`).

Everything a customer bought. The customer's 10 orders are cheap to find, but the join reads all 1.5 million order items.

## Expected result.

`order_items (order_id)`. The join becomes a nested loop that probes it 10 times.

## Proof.

`ruby e2e/verify.rb 012` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
