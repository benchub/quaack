# Case 004: Sort under a LIMIT.

**Category:** `index`, new index only.

**Exercises:** Sort under a Limit (5a-2); ORDER BY columns after the equality column (5a-1); DESC sort direction.

## Setup.

`posts` has 500,000 rows for 200 authors. Only `author_id` is indexed. Every `created_at` is distinct, so the `ORDER BY` is a total order.

## Slow query (`slow.sql`).

An author's 20 newest posts. Postgres fetches all 2,500 of the author's posts, sorts them, and keeps 20.

## Expected result.

`posts (author_id, created_at DESC)`. The scan comes out sorted and stops after 20 rows.

## Proof.

`ruby e2e/verify.rb 004` checks the claims above. The measured table is in `results.md`.
