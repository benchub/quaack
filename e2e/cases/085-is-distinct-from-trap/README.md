# Case 085: IS DISTINCT FROM to <>.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** IS DISTINCT FROM includes NULL; NULL fixtures (rewrite-test, S2).

## Setup.

Case 084's `issues`. 5% have a NULL `team_id`.

## Slow query (`slow.sql`).

Count issues that don't belong to team 7.

## Expected result.

QUAACK must reject `team_id <> 7`, which drops the 25,000 issues with no team.

## Proof.

`ruby e2e/verify.rb 085` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
