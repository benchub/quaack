# Case 063: Date equality to a closed BETWEEN.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** BETWEEN ... 23:59:59 misses fractional seconds; boundary-value fixtures (step 9, S5); one unit past the literal (step 9).

## Setup.

`logins` has 400,000 rows, 7.5 seconds apart, plus one at 23:59:59.5 on each of 30 days.

## Slow query (`slow.sql`).

Logins on one day.

## Expected result.

QUAACK must reject the closed `BETWEEN`, which misses logins in the last half second of the day. The correct rewrite is the half-open range from case 046. Step 9's boundary values, one unit past the literal, should catch it.

## Proof.

`ruby e2e/verify.rb 063` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
