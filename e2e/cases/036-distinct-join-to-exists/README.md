# Case 036: SELECT DISTINCT over a fan-out join.

**Category:** `none`, nothing beats the original (negative result).

**Exercises:** DISTINCT to remove join fan-out; semi-join rewrite; uniqueness assumption (6b); generator-one candidates already exist, so 5a-3 drops them.

## Setup.

Case 001's `customers` and `orders`. `customers (tier) INCLUDE (email)` and `orders (customer_id, total_cents)` already exist: the indexes generator one would propose for this query.

## Slow query (`slow.sql`).

Gold customers with a big order. The join returns one row per qualifying order, and `DISTINCT` sorts them back down.

## Expected result.

The obvious rewrite is `EXISTS` (`fast.sql`), which is correct. Stated assumption: `customers.id` is unique. But with these indexes, Postgres 18 already plans the `DISTINCT` join about as well as the semi-join, so 14a and 14b must reject the rewrite. The generator-one indexes already exist, so 5a-3 drops them as duplicates. QUAACK should report a negative result (15a) that names the rewrite and why it lost.

## Proof.

`ruby e2e/verify.rb 036` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
