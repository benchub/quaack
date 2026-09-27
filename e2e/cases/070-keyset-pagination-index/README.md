# Case 070: Keyset pagination with a row comparison.

**Category:** `index`, new index only.

**Exercises:** row comparison for keyset pagination (SupportedSql); Sort under a Limit (5a-2); DESC sort direction.

## Setup.

Case 001's `customers` and `orders`. `orders.created_at` isn't indexed.

## Slow query (`slow.sql`).

The next page of orders, keyset-paginated with the row comparison `(created_at, id) < (...)`. Postgres scans the orders before the cursor, sorts them, and keeps 50.

## Expected result.

`orders (created_at DESC, id DESC)`. The scan starts at the cursor, comes out sorted, and stops after 50 rows.

## Proof.

`ruby e2e/verify.rb 070` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
