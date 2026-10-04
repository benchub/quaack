# Case 093: now(), current_timestamp, and localtimestamp.

**Category:** `index`, new index only.

**Exercises:** now() anchored (clock-anchor); current_timestamp anchored (clock-anchor); localtimestamp anchored (clock-anchor).

## Setup.

`reminders` holds 500,000 rows spread about 50 days either side of the day it's loaded. Nothing indexes `due_at`.

## Slow query (`slow.sql`).

Today's reminders.

## Expected result.

`reminders (due_at)`. QUAACK must anchor `now()`, `current_timestamp`, and `localtimestamp` to `quaack.clock_anchor()` (clock-anchor), and put them back in the report.

## Notes.

The query only depends on the date, so run the proof away from midnight UTC.

## Proof.

`ruby e2e/verify.rb 093` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
