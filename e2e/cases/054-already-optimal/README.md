# Case 054: A query that's already well indexed.

**Category:** `none`, nothing beats the original (negative result).

**Exercises:** negative result (15a); proposed index already covered by an existing one (5a-3); duplicate recorded with the index that covers it.

## Setup.

Case 001's `customers` and `orders`, with `orders (customer_id, created_at DESC)` already indexed.

## Slow query (`slow.sql`).

A customer's five latest orders. The existing index already serves it perfectly.

## Expected result.

Nothing. Generator one's `orders (customer_id)` is a leading prefix of the existing index, so 5a-3 drops it and records the covering index for 15a. `indexes.sql` builds it anyway, to show it wouldn't help. QUAACK should end with a negative result.

## Proof.

`ruby e2e/verify.rb 054` checks the claims above. The measured table is in `results.md`.
