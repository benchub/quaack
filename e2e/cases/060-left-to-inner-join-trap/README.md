# Case 060: LEFT JOIN to INNER JOIN.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** LEFT JOIN with no match; orphan fixtures (step 9, S4); count over an outer join.

## Setup.

60,000 `customers`, of whom the last 10,000 have no orders. Case 001's `orders`.

## Slow query (`slow.sql`).

Order counts per gold customer, including those with none.

## Expected result.

QUAACK must reject the inner join, which drops the 200 gold customers with zero orders.

## Proof.

`ruby e2e/verify.rb 060` checks the claims above. The measured table is in `results.md`.
