# Case 014: Two single-column indexes combined with BitmapAnd.

**Category:** `index`, new index only.

**Exercises:** BitmapAnd of single-column indexes (index-from-plan); two equality columns ranked by selectivity (index-from-query).

## Setup.

`listings` has 600,000 rows. `city_id` and `bedrooms` each have their own index.

## Slow query (`slow.sql`).

Search by city and size. Postgres combines the two indexes (or uses the city index and filters). Either way it reads index entries and heap pages for rows that match only one condition.

## Expected result.

One composite index, `listings (city_id, bedrooms)`, with the more selective `city_id` first.

## Proof.

`ruby e2e/verify.rb 014` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
