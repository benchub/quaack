# Case 090: LIKE prefix under COLLATE "C".

**Category:** `index`, new index only.

**Exercises:** COLLATE clause; index with a matching collation; ORDER BY with COLLATE.

## Setup.

`companies` has 400,000 rows, with an ordinary index on `name` in the `en_US.utf8` collation.

## Slow query (`slow.sql`).

Prefix search with byte-order sorting, written with `COLLATE "C"`. The `en_US.utf8` index can't serve it.

## Expected result.

`companies (name COLLATE "C")`. The collation must match the query's, and index-dedupe must treat it as a different key from `companies_name_idx`.

## Proof.

`ruby e2e/verify.rb 090` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
