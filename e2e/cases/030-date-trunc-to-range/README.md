# Case 030: date_trunc on an indexed column.

**Category:** `rewrite`, rewrite only.

**Exercises:** non-sargable function on an indexed column; shared placeholder between GROUP BY and the select list (3g); range rewrite depends on TimeZone (step 2).

## Setup.

Case 001's `customers` and `orders`, with `orders.created_at` indexed. `created_at` runs in insert order, so it's perfectly correlated.

## Slow query (`slow.sql`).

Daily totals for March. `date_trunc` on the column hides it from the index, so Postgres scans the whole table.

## Expected result.

A half-open range on `created_at`. The month literal appears twice in the rewrite. Both copies take the same value, as the rewrite's placeholder rules require.

Stated assumptions:
- The literal is the start of a month. For `'2025-03-15'` the original matches nothing, but the range still matches from the 15th on. That's a literal-dependent rewrite. 3e keeps the slow literal for a placeholder compared with a function, so QUAACK's literal sets all satisfy it, but step 9 or 10 should try a mid-month value.
- The literal has no UTC offset. `date_trunc` works in the session's `TimeZone`, and so do the unzoned literal and `+ interval '1 month'`, so the two agree in any time zone. With a `+00` literal they'd agree only in a UTC session.

## Notes.

The `'day'` and `'month'` literals in the select list and the `GROUP BY` must share one placeholder (3g), or the redacted query won't prepare.

## Proof.

`ruby e2e/verify.rb 030` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
