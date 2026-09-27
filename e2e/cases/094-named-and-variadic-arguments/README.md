# Case 094: Named and VARIADIC function arguments.

**Category:** `index`, new index only.

**Exercises:** named argument (=>); VARIADIC argument; immutable function folded to a constant.

## Setup.

`people` has 400,000 rows, the newest from early October 2025. Nothing indexes `signed_up_at`.

## Slow query (`slow.sql`).

Recent sign-ups with their full names. The cutoff uses a named argument, and the name uses a `VARIADIC` array.

## Expected result.

`people (signed_up_at)`. `make_interval` is immutable, so the cutoff folds to a constant the index can use.

## Proof.

`ruby e2e/verify.rb 094` checks the claims above. The measured table is in `results.md`.
