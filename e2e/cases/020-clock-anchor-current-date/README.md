# Case 020: Filter relative to CURRENT_DATE.

**Category:** `index`, new index only.

**Exercises:** clock function anchored to quaack.clock_anchor() (clock-anchor); range predicate against an expression; report puts the original function back (clock-anchor).

## Setup.

`sessions` holds about 60 days of rows that end just before the start of today, generated relative to the day it's loaded.

## Slow query (`slow.sql`).

Yesterday's sessions per user. `current_date` is a clock function, and nothing indexes `started_at`.

## Expected result.

`sessions (started_at)`. QUAACK must anchor `current_date` to `quaack.clock_anchor()` before planning (clock-anchor), and show `current_date` again in the report.

## Notes.

Both queries only read `current_date`, which changes at midnight, so run the proof away from midnight UTC.

## Proof.

`ruby e2e/verify.rb 020` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
