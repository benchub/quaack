# Case 044: IN over a subquery that re-sorts a big table.

**Category:** `rewrite`, rewrite only.

**Exercises:** IN (SELECT DISTINCT ...); semi-join from the small side.

## Setup.

Case 001's `customers` and `orders`, with `orders.customer_id` indexed.

## Slow query (`slow.sql`).

An ORM wrote the customer lookup as `IN (SELECT DISTINCT ...)`.

## Expected result.

A plain join. Stated assumption: `customers.email` is unique, so the join can't duplicate orders. The win is small, about 13% on the slow literals, because Postgres already turns the `IN` into a semi-join. What remains is the cost of the `DISTINCT` step.

## Proof.

`ruby e2e/verify.rb 044` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
