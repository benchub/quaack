# Case 002: Foreign key with no index.

**Category:** `index`, new index only.

**Exercises:** seq scan with a selective equality filter (5a-2); btree from an equality atom (5a-1); ORDER BY after the equality column.

## Setup.

Same `customers` and `orders` as case 001, but nobody indexed `orders.customer_id`.

## Slow query (`slow.sql`).

A customer's order history. With no index on the foreign key, Postgres reads all 500,000 orders to find 10.

## Expected result.

An index on `orders (customer_id)`. Generator one may also offer `(customer_id, created_at DESC)` with the rest as `INCLUDE` columns, which is at least as good. Either counts as finding it.

## Proof.

`ruby e2e/verify.rb 002` checks the claims above. The measured table is in `results.md`.
