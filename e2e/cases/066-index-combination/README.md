# Case 066: Two missing indexes on two tables.

**Category:** `index`, new index only.

**Exercises:** greedy combination of candidates (5a-7); range column plus a join key; Hash Join with a large inner build (5a-2).

## Setup.

Case 012's `orders`, `order_items`, and `products`. Neither `orders.created_at` nor `order_items.order_id` is indexed.

## Slow query (`slow.sql`).

Units sold per category in the last day. Postgres scans all of `orders` for the day's orders, then all 1.5 million order items to join them.

## Expected result.

Both `orders (created_at)` and `order_items (order_id)`. Each one alone fixes only half the plan, so 5a-7's greedy combination should keep the pair as its best combination.

## Notes.

Measured on the slow literals when this case was written: the original touched 16,049 blocks, `orders (created_at)` alone 11,165, `order_items (order_id)` alone 12,091, and the pair 7,153.

## Proof.

`ruby e2e/verify.rb 066` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
