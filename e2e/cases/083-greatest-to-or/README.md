# Case 083: GREATEST over two indexed columns.

**Category:** `rewrite`, rewrite only.

**Exercises:** GREATEST; LEAST; NULLIF; OR of two range predicates (BitmapOr); GREATEST ignores NULLs.

## Setup.

`docs` has 500,000 rows. `created_at` and `updated_at` are each indexed, and `updated_at` is NULL for 40% of rows.

## Slow query (`slow.sql`).

Documents touched recently. `GREATEST(...)` hides both columns from their indexes.

## Expected result.

`updated_at >= x OR created_at >= x`, which Postgres runs as a BitmapOr of the two indexes. It's equivalent even with NULLs: `GREATEST` ignores a NULL `updated_at`, and `NULL OR created_at >= x` is true exactly when `created_at >= x`.

## Proof.

`ruby e2e/verify.rb 083` checks the claims above. The measured table is in `results.md`.
