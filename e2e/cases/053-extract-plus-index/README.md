# Case 053: extract() on a timestamptz, no index.

**Category:** `both`, rewrite + new index.

**Exercises:** extract on the column; two placeholders collapse into one range; stable function: no expression index possible.

## Setup.

Case 001's `customers` and `orders`. Nothing indexes `created_at`.

## Slow query (`slow.sql`).

July's totals, written with `extract()`. `extract` on a `timestamptz` isn't immutable, so no expression index can serve it.

## Expected result.

A half-open range built from the same year and month, plus `orders (created_at) INCLUDE (total_cents)`. `make_timestamptz` uses the session time zone, like `extract`, so the two agree when the time zones match (run-server). Both literals are compared with `extract(...)`, so literals keeps the slow literals in every set. The other sets here only prove equivalence.

## Proof.

`ruby e2e/verify.rb 053` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
