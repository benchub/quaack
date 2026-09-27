# Case 068: EXCEPT whose second arm is a range scan.

**Category:** `index`, new index only.

**Exercises:** EXCEPT set operation; range-only arm: generator one keys on the range column (5a-1); INCLUDE column for an index-only scan.

## Setup.

Case 001's `customers` and `orders`, with `orders (customer_id, total_cents)` and `customers (tier, region)` indexed.

## Slow query (`slow.sql`).

Gold APAC customers who never placed a big order, written with `EXCEPT`. The second arm reads every big order through the `(customer_id, total_cents)` index, all of it.

## Expected result.

`orders (total_cents) INCLUDE (customer_id)`: generator one's candidate for the second arm, which has only a range column and selects `customer_id`. It reads just the big orders, index-only.

The tempting rewrite to `NOT EXISTS` is correct, given that `customers.id` is unique and `orders.customer_id` is `NOT NULL`, but it touches more blocks than the original here, so QUAACK should reject it.

## Proof.

`ruby e2e/verify.rb 068` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
