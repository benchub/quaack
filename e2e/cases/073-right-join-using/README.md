# Case 073: RIGHT JOIN with USING.

**Category:** `none`, nothing beats the original (negative result).

**Exercises:** RIGHT JOIN; JOIN ... USING; outer-join rows with no match; index that wins on the slow literal but loses on the worst case: rejected by minimax (14b).

## Setup.

20,000 `accounts`, 40 of them enterprise. 450,000 `sessions` for accounts 1 to 18,000, so four enterprise accounts have none. `sessions.account_id` isn't indexed.

## Slow query (`slow.sql`).

Enterprise accounts with their sessions, keeping accounts that have none. The join reads every session.

## Expected result.

Nothing should be accepted. `sessions (account_id)` cuts the slow literal's blocks by two-thirds, which passes 14a. But on the worst-case literal (`'free'`, the top MCV, 16,000 accounts), the planner switches to a nested loop over the index and touches about 60 times more blocks than the original. 14b must reject the index, and the report should say which literal set sank it. The four enterprise accounts with no sessions come back once each, with a NULL `started_at`, in every plan.

## Proof.

`ruby e2e/verify.rb 073` checks the claims above. The measured table is in `results.md`.
