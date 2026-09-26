# Case 001: OR across two joined tables.

**Category:** `both`, rewrite + new index.

**Exercises:** OR across a join; UNION rewrite; btree from an equality atom (5a-1); index unused by the original (15a); uniqueness assumption checked in 6b.

## Setup.

`customers` has 50,000 rows with a unique `email`. `orders` has 500,000 rows, 10 per customer, spread through the heap. `orders.tracking_number` is NULL for pending and cancelled orders, and nothing indexes it. `orders.customer_id` has the usual FK index.

## Slow query (`slow.sql`).

A support search: orders matching the customer's email *or* a tracking number. The `OR` spans both sides of the join, so neither branch can drive an index. Postgres hash-joins every order to its customer and filters afterwards.

## Expected result.

- **Rewrite (`fast.sql`):** split the `OR` into a `UNION` of the two branches. Stated assumption: `orders.id` is unique and each order joins at most one customer, so the original never returns duplicate rows for `UNION` to collapse.
- **Index (`indexes.sql`):** `orders (tracking_number)`. Generator one should propose it from the equality atom in the rewrite's own index search (step 8).
- The index alone changes nothing: the planner ignores it for the original, which 15a should report. The rewrite alone is about 25% better, so it's a valid candidate too, but it ranks below rewrite + index.

## Notes.

The "same customer" set proves the rewrite: the `OR` returns 10 rows, and a wrong `UNION ALL` rewrite would return 11.

## Proof.

`ruby e2e/verify.rb 001` checks the claims above. The measured table is in `results.md`.
