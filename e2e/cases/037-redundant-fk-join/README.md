# Case 037: Join that only re-checks a foreign key.

**Category:** `rewrite`, rewrite only.

**Exercises:** join elimination; validated FK plus NOT NULL assumption (assumption-check); NOT VALID constraints don't count (assumption-check).

## Setup.

Case 001's `customers` and `orders`, with `orders.created_at` indexed. `orders.customer_id` is `NOT NULL` with a validated foreign key.

## Slow query (`slow.sql`).

December's orders. The join selects nothing from `customers`. It only checks that each order's customer exists, which the foreign key already guarantees.

## Expected result.

Drop the join. Stated assumptions: `orders.customer_id` is `NOT NULL`, and its foreign key to `customers.id` is valid. If the constraint were `NOT VALID`, assumption-check would treat it as missing and reject the rewrite.

## Proof.

`ruby e2e/verify.rb 037` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
