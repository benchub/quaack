# Case 051: Three scalar counts, each scanning a range.

**Category:** `both`, rewrite + new index.

**Exercises:** uncorrelated scalar subqueries; aggregate FILTER; range index shared by the branches.

## Setup.

Case 001's `customers` and `orders`. Nothing indexes `created_at` or `status`.

## Slow query (`slow.sql`).

December's status counts, as three scalar subqueries that each scan the table.

## Expected result.

One pass with `FILTER`, plus `orders (created_at) INCLUDE (status)` for an index-only range scan. The index alone still runs three range scans, and the rewrite alone still scans the whole table once.

## Notes.

Each subquery has its own copy of the date literal. The rewrite keeps one copy, which is fine because all three copies hold the same value in every literal set.

## Proof.

`ruby e2e/verify.rb 051` checks the claims above. The measured table is in `results.md`.
