# Case 024: BETWEEN on a price.

**Category:** `index`, new index only.

**Exercises:** BETWEEN atom; BETWEEN worst case is the first and last histogram bounds (3e); no worse on the worst-case literal (14b).

## Setup.

`homes` has 500,000 rows with prices spread from $100,000 to $1,000,000.

## Slow query (`slow.sql`).

Homes in a narrow price band. A full scan finds about 50 rows.

## Expected result.

`homes (price_cents)`. For the worst-case literal, which covers almost everything, the planner keeps the sequential scan, so it's no worse.

## Proof.

`ruby e2e/verify.rb 024` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
