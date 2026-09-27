# Case 086: BETWEEN SYMMETRIC with NOT BETWEEN, NOT IN, NOT LIKE, and <> ALL.

**Category:** `index`, new index only.

**Exercises:** BETWEEN SYMMETRIC; NOT BETWEEN; NOT BETWEEN SYMMETRIC; NOT IN list; NOT LIKE; <> ALL (ARRAY[...]).

## Setup.

`catalog` has 500,000 rows. Only the primary key is indexed.

## Slow query (`slow.sql`).

A price-band search with several exclusions. The band is written high-to-low, which `SYMMETRIC` allows.

## Expected result.

`catalog (price_cents)` for the band. The negations can't use an index and stay as filters.

## Proof.

`ruby e2e/verify.rb 086` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
