# Case 074: FULL JOIN filtered after the join.

**Category:** `rewrite`, rewrite only.

**Exercises:** FULL JOIN; COALESCE over both sides; IS DISTINCT FROM; filter pushed into subqueries in FROM.

## Setup.

`bank_rows` and `book_rows` each have about 200,000 rows in 2,000 batches, with `batch_id` indexed on both. Some rows are missing on one side, and some amounts disagree.

## Slow query (`slow.sql`).

Reconcile one batch. `COALESCE(b.batch_id, k.batch_id)` can only be evaluated after the full join, so both tables are read in full.

## Expected result.

Filter each side to the batch before the `FULL JOIN`. The join condition includes `batch_id`, so matched rows share a batch and unmatched rows keep their own. Filtering first gives exactly the same rows, and each side uses its index.

## Proof.

`ruby e2e/verify.rb 074` checks the claims above. The measured table is in `results.md`.
