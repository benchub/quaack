# Case 079: DISTINCT, ORDER BY, and WITHIN GROUP aggregates.

**Category:** `index`, new index only.

**Exercises:** aggregate with DISTINCT; aggregate with ORDER BY; ordered-set aggregate WITHIN GROUP; float result compared with a tolerance (fixture-compare).

## Setup.

Case 001's `customers` and `orders`, with no index on `customer_id`.

## Slow query (`slow.sql`).

A per-customer summary: distinct statuses, status history in order, and median order size.

## Expected result.

`orders (customer_id)`. The aggregates don't change, only how the rows are found.

## Proof.

`ruby e2e/verify.rb 079` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
