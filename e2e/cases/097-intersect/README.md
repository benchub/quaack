# Case 097: INTERSECT of two date ranges.

**Category:** `index`, new index only.

**Exercises:** INTERSECT; two range scans on one column.

## Setup.

Case 001's `customers` and `orders`, with no index on `created_at`.

## Slow query (`slow.sql`).

Customers who ordered in the first ten days of both November and December. Each branch scans the whole table.

## Expected result.

`orders (created_at) INCLUDE (customer_id)`: two index-only range scans.

## Proof.

`ruby e2e/verify.rb 097` checks the claims above. The measured table is in `results.md`.
