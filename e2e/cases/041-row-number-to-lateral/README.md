# Case 041: row_number() over everything, then filter.

**Category:** `none`, nothing beats the original (negative result).

**Exercises:** window function with PARTITION BY; LATERAL top-N rewrite; existing index used by the rewrite; generator-one candidates already exist, so index-dedupe drops them.

## Setup.

Case 001's `customers` and `orders`, with `orders (customer_id, created_at DESC, id DESC)` and `customers (tier, id)` indexed.

## Slow query (`slow.sql`).

Each gold customer's three latest orders, via `row_number()`. Postgres ranks every order of every gold customer, then keeps three per customer.

## Expected result.

The textbook rewrite is a `LATERAL` subquery with `LIMIT 3` (`fast.sql`), which is correct. But with the `(customer_id, created_at DESC, id DESC)` index in place, Postgres 18 plans the `row_number()` version nearly as well. The difference is under 5%, so QUAACK should report a negative result. `indexes.sql` tries a covering `orders (customer_id) INCLUDE (id, created_at)`, which doesn't help. Case 027 is the same shape with the index missing.

## Proof.

`ruby e2e/verify.rb 041` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
