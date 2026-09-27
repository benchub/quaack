# Case 056: Lookup in a tiny table.

**Category:** `none`, nothing beats the original (negative result).

**Exercises:** negative result (15a); sequential scan of a two-page table.

## Setup.

`countries` has 250 rows, which fit in two pages.

## Slow query (`slow.sql`).

Look up a country by name. The whole table is two pages.

## Expected result.

Nothing. An index on `name` can't beat reading two pages by more than 5%. It exercises the case where the "slow" query isn't slow.

## Proof.

`ruby e2e/verify.rb 056` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
