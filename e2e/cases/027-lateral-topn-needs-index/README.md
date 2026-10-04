# Case 027: LATERAL top-N with no index to stop early.

**Category:** `index`, new index only.

**Exercises:** LATERAL subquery; ORDER BY ... LIMIT inside a correlated subquery; Nested Loop inner side (index-from-plan).

## Setup.

Case 001's `customers` and `orders`. `orders.customer_id` is indexed.

## Slow query (`slow.sql`).

Each gold customer's three latest orders. Per customer, Postgres fetches all 10 orders and sorts them to keep three.

## Expected result.

`orders (customer_id, created_at DESC, id DESC)`. Each lateral probe reads three index entries and stops.

## Proof.

`ruby e2e/verify.rb 027` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
