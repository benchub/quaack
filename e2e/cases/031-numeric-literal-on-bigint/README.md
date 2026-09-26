# Case 031: Numeric literal against a bigint column.

**Category:** `rewrite`, rewrite only.

**Exercises:** implicit cast of the column to numeric; cast the literal instead; typical ORM parameter bug.

## Setup.

Case 001's `customers` and `orders`, with `orders.customer_id` indexed.

## Slow query (`slow.sql`).

A driver sends the id as a numeric. `bigint = numeric` casts the column, so the index can't be used.

## Expected result.

Cast the literal to `bigint` instead. Stated assumption: the parameter is always a whole number. The literal sets all are, since 3e takes them from `customer_id`'s own statistics.

## Notes.

For `4242.5` the rewrite would round and match customer 4243, so the assumption matters. No literal set uses a fraction.

## Proof.

`ruby e2e/verify.rb 031` checks the claims above. The measured table is in `results.md`.
