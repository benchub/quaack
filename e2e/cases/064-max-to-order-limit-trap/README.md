# Case 064: max() to ORDER BY ... DESC LIMIT 1.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** NULLs sort first in DESC order; aggregate over nullable column; NULL fixtures (step 9, S2).

## Setup.

`deliveries` has 300,000 rows. One in 40 is undelivered, with a NULL `delivered_at`.

## Slow query (`slow.sql`).

A route's latest delivery.

## Expected result.

QUAACK must reject `ORDER BY delivered_at DESC LIMIT 1`. NULLs sort first in descending order, so it returns NULL where `max` skips NULLs. `DESC NULLS LAST` would be correct.

## Proof.

`ruby e2e/verify.rb 064` checks the claims above. The measured table is in `results.md`.
