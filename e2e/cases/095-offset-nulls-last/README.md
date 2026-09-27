# Case 095: OFFSET pagination with NULLS LAST.

**Category:** `index`, new index only.

**Exercises:** OFFSET; ORDER BY ... DESC NULLS LAST; index sort order must match NULLS placement.

## Setup.

`shipments` has 500,000 rows for four carriers. Some `shipped_at` values are NULL.

## Slow query (`slow.sql`).

Page three of a carrier's shipments, newest first, unshipped last. Postgres sorts the carrier's 125,000 rows each time.

## Expected result.

`shipments (carrier, shipped_at DESC NULLS LAST, id DESC)`. The `NULLS LAST` must match, or the index can't replace the sort.

## Notes.

The deep page, near the unshipped rows at the end, only proves equivalence. It isn't a 3e set.

## Proof.

`ruby e2e/verify.rb 095` checks the claims above. The measured table is in `results.md`.
