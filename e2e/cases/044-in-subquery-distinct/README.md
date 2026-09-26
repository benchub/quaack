# Case 044: IN over a subquery that re-sorts a big table.

**Category:** `rewrite`, rewrite only.

**Exercises:** IN (SELECT DISTINCT ...); semi-join from the small side.

## Setup.

Case 001's `customers` and `orders`, with `orders.customer_id` indexed.

## Slow query (`slow.sql`).

An ORM wrote the customer lookup as `IN (SELECT DISTINCT ...)`.

## Expected result.

A plain join. Stated assumption: `customers.email` is unique, so the join can't duplicate orders. If Postgres already plans the `IN` as well as the join, this is a negative result for the rewrite. `results.md` shows which.

## Proof.

`ruby e2e/verify.rb 044` checks the claims above. The measured table is in `results.md`.
