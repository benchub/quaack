# Case 045: Filter on a grouped column written in HAVING.

**Category:** `none`, nothing beats the original (negative result).

**Exercises:** HAVING without an aggregate; planner moves it to WHERE on its own.

## Setup.

Case 001's `customers` and `orders`, with `orders.customer_id` indexed.

## Slow query (`slow.sql`).

A per-customer total, with the customer filter written in `HAVING`.

## Expected result.

Moving the filter to `WHERE` is correct, but Postgres already does it: a `HAVING` clause with no aggregate is pushed down to `WHERE`. So this rewrite isn't more than 5% better, and QUAACK should report a negative result for it (15a).

## Proof.

`ruby e2e/verify.rb 045` checks the claims above. The measured table is in `results.md`.
