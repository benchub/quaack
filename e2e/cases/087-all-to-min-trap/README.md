# Case 087: < ALL (subquery) to < (SELECT min(...)).

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** ALL subquery; ALL over an empty set is true; orphan fixtures (step 9, S4).

## Setup.

20,000 `items`. Every fourth item has no competitor prices.

## Slow query (`slow.sql`).

Items cheaper than every competitor.

## Expected result.

QUAACK must reject the `min` rewrite. `< ALL` over no rows is true, but `< min(...)` over no rows is NULL, so items with no competitors vanish.

## Proof.

`ruby e2e/verify.rb 087` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
