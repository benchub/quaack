# Case 070: Keyset pagination with a row comparison.

**Category:** `refused`, QUAACK v1 must refuse the query.

**Exercises:** ROW comparison is unsupported in v1 (SupportedSql); refusal names only the rule.

## Setup.

Case 001's `customers` and `orders`.

## Slow query (`slow.sql`).

The next page of orders, keyset-paginated with a row comparison.

## Expected result.

`quaacks intake` must refuse it with `unsupported_construct` (row comparisons aren't in v1), before any run starts, and the error must not quote the query.

## Proof.

`ruby e2e/verify.rb 070` checks the claims above. The measured table is in `results.md`.
