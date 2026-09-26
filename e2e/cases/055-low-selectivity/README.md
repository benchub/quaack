# Case 055: Filter that matches most of the table.

**Category:** `none`, nothing beats the original (negative result).

**Exercises:** negative result (15a); index the planner declines to use (5a-4); top-MCV literal.

## Setup.

Case 001's `customers` and `orders`. 80% of orders are shipped.

## Slow query (`slow.sql`).

The total of shipped orders. It reads 80% of the table, so a sequential scan is already right.

## Expected result.

Nothing. `orders (status)` is the obvious candidate, but the planner doesn't use it for a value that covers 80% of rows. 5a-4 discards it and records that it went unused, and the report explains why.

## Proof.

`ruby e2e/verify.rb 055` checks the claims above. The measured table is in `results.md`.
