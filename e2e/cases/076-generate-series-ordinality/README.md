# Case 076: Calendar from generate_series WITH ORDINALITY.

**Category:** `index`, new index only.

**Exercises:** function in FROM (generate_series); WITH ORDINALITY and a column alias list; LEFT JOIN on a range condition.

## Setup.

Case 001's `customers` and `orders`, with no index on `created_at`.

## Slow query (`slow.sql`).

Orders per day for a week, including days with none, driven by a calendar from `generate_series`.

## Expected result.

`orders (created_at)`. Each day becomes one index range scan instead of a pass over the whole table.

## Proof.

`ruby e2e/verify.rb 076` checks the claims above. The measured table is in `results.md`.
