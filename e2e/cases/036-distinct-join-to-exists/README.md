# Case 036: SELECT DISTINCT over a fan-out join.

**Category:** `none`, nothing beats the original (negative result).

**Exercises:** DISTINCT to remove join fan-out; semi-join rewrite; uniqueness assumption (6b).

## Setup.

Case 001's `customers` and `orders`, with `orders.customer_id` indexed.

## Slow query (`slow.sql`).

Gold customers with a big order. The join returns one row per qualifying order, and `DISTINCT` sorts them back down.

## Expected result.

The obvious rewrite is `EXISTS` (`fast.sql`), which is correct. Stated assumption: `customers.id` is unique. But Postgres 18 already plans the `DISTINCT` join well, and the `EXISTS` version touches more blocks on the slow literals, so 14a and 14b must reject it. QUAACK should report a negative result (15a) that names the rewrite and why it lost.

## Proof.

`ruby e2e/verify.rb 036` checks the claims above. The measured table is in `results.md`.
