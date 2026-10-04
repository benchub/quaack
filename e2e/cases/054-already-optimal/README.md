# Case 054: A query that's already well indexed.

**Category:** `none`, nothing beats the original (negative result).

**Exercises:** negative result (negative-result); proposed index already covered by an existing one (index-dedupe); duplicate recorded with the index that covers it.

## Setup.

Case 001's `customers` and `orders`, with `orders (customer_id, created_at DESC) INCLUDE (id, total_cents)` already indexed.

## Slow query (`slow.sql`).

A customer's five latest orders. The existing index already serves it perfectly.

## Expected result.

Nothing. Generator one's candidate, `orders (customer_id, created_at DESC) INCLUDE (id, total_cents)`, is the existing index, so index-dedupe drops it and records the covering index for negative-result. `indexes.sql` builds a close variant with `id` in the key, to show that doesn't help either. QUAACK should end with a negative result.

## Proof.

`ruby e2e/verify.rb 054` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
