# Case 068: EXCEPT over a big table.

**Category:** `none`, nothing beats the original (negative result).

**Exercises:** EXCEPT set operation; anti-join rewrite; set operations treat NULLs as equal: NOT NULL assumption (6b).

## Setup.

Case 001's `customers` and `orders`, with `orders (customer_id, total_cents)` and `customers (tier, region)` indexed: generator one's candidates for both sides.

## Slow query (`slow.sql`).

Gold APAC customers who never placed a big order, written with `EXCEPT`.

## Expected result.

The obvious rewrite is `NOT EXISTS` (`fast.sql`), which is correct. Stated assumptions: `customers.id` is unique (`EXCEPT` removes duplicates) and `orders.customer_id` is `NOT NULL` (`EXCEPT` treats NULLs as equal). But Postgres reads the big orders with an index-only scan of `(customer_id, total_cents)`, which is already cheap, and the per-customer probes of `NOT EXISTS` touch more blocks. QUAACK should reject the rewrite and report a negative result.

## Proof.

`ruby e2e/verify.rb 068` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
