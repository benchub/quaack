# Case 043: OR across a join, both columns indexed.

**Category:** `rewrite`, rewrite only.

**Exercises:** OR across a join; UNION rewrite; existing indexes are enough.

## Setup.

Case 001's schema, but `tracking_number` is already indexed.

## Slow query (`slow.sql`).

The same search as case 001. Both columns are indexed, but the `OR` across the join still forces a full join.

## Expected result.

The `UNION` rewrite from case 001. Here, no new index is needed.

## Proof.

`ruby e2e/verify.rb 043` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
