# Case 101: SIMILAR TO pattern.

**Category:** `refused`, QUAACK v1 must refuse the query.

**Exercises:** SIMILAR TO is unsupported in v1 (SupportedSql).

## Setup.

Case 001's `customers`.

## Slow query (`slow.sql`).

Customers whose email matches a SIMILAR TO pattern.

## Expected result.

`quaacks intake` must refuse it with `unsupported_construct`.

## Proof.

`ruby e2e/verify.rb 101` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
