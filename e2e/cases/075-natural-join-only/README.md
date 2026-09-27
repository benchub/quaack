# Case 075: NATURAL JOIN on an inheritance parent with ONLY.

**Category:** `index`, new index only.

**Exercises:** NATURAL JOIN; FROM ONLY on an inheritance parent; indexes aren't inherited.

## Setup.

`events` holds 400,000 rows, and its child `events_2024` holds 100,000 more. `event_kinds` shares only `kind_code` with `events`.

## Slow query (`slow.sql`).

This year's events for one account, with their labels. `ONLY` leaves out the child table, and nothing indexes `account_id`.

## Expected result.

`events (account_id)` on the parent. Indexes aren't inherited, and `ONLY` means the child doesn't need one.

## Proof.

`ruby e2e/verify.rb 075` checks the claims above. The measured table is in `results.md`.
