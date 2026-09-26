# Case 030: date_trunc on an indexed column.

**Category:** `rewrite`, rewrite only.

**Exercises:** non-sargable function on an indexed column; shared placeholder between GROUP BY and the select list (3g); range rewrite depends on TimeZone (step 2).

## Setup.

Case 001's `customers` and `orders`, with `orders.created_at` indexed. `created_at` runs in insert order, so it's perfectly correlated.

## Slow query (`slow.sql`).

Daily totals for March. `date_trunc` on the column hides it from the index, so Postgres scans the whole table.

## Expected result.

A half-open range on `created_at`. The month literal appears twice in the rewrite. Both copies take the same value, as the rewrite's placeholder rules require.

## Notes.

The `'day'` literal in the select list and the `GROUP BY` must share one placeholder (3g), or the redacted query won't prepare.

## Proof.

`ruby e2e/verify.rb 030` checks the claims above. The measured table is in `results.md`.
