# Case 037: Join that only re-checks a foreign key.

**Category:** `rewrite`, rewrite only.

**Exercises:** join elimination; validated FK plus NOT NULL assumption (6b); NOT VALID constraints don't count (6b).

## Setup.

Case 001's `customers` and `orders`, with `orders.created_at` indexed. `orders.customer_id` is `NOT NULL` with a validated foreign key.

## Slow query (`slow.sql`).

December's orders. The join selects nothing from `customers`. It only checks that each order's customer exists, which the foreign key already guarantees.

## Expected result.

Drop the join. Stated assumptions: `orders.customer_id` is `NOT NULL`, and its foreign key to `customers.id` is valid. If the constraint were `NOT VALID`, 6b would treat it as missing and reject the rewrite.

## Proof.

`ruby e2e/verify.rb 037` checks the claims above. The measured table is in `results.md`.
