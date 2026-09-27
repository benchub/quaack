# Case 071: ROLLUP report.

**Category:** `refused`, QUAACK v1 must refuse the query.

**Exercises:** GROUPING SETS / ROLLUP is unsupported in v1 (SupportedSql).

## Setup.

Case 001's `customers`.

## Slow query (`slow.sql`).

Customer counts by region and tier, with subtotals.

## Expected result.

`quaacks intake` must refuse it with `unsupported_construct`.

## Proof.

`ruby e2e/verify.rb 071` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
