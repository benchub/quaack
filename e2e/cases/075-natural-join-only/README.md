# Case 075: NATURAL JOIN with ONLY.

**Category:** `index`, new index only.

**Exercises:** NATURAL JOIN; FROM ONLY on a table with no inheritance children. README statistics refuses a table with children (`inheritance_parent`), with or without `ONLY`, so the case has none.

## Setup.

`events` holds 400,000 rows. `event_kinds` shares only `kind_code` with `events`.

## Slow query (`slow.sql`).

This year's events for one account, with their labels. `ONLY` is a no-op here, and nothing indexes `account_id`.

## Expected result.

`events (account_id)`.

## Proof.

`ruby e2e/verify.rb 075` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
