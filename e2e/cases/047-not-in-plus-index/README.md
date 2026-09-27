# Case 047: NOT IN with no index on the inner key.

**Category:** `both`, rewrite + new index.

**Exercises:** NOT IN subquery; anti-join rewrite; NOT NULL assumption (6b); index on the anti-join key.

## Setup.

Case 034's data, but `orders.customer_id` isn't indexed.

## Slow query (`slow.sql`).

Gold APAC customers who never ordered, as in case 034.

## Expected result.

`NOT EXISTS` plus `orders (customer_id)`. Without the index, the anti-join still reads every order. Without the rewrite, `NOT IN` can't use the index.

## Notes.

As in case 034, 3e's top-MCV set (`tier = 'standard'`) would make the original run for many minutes, so it's left out.

## Proof.

`ruby e2e/verify.rb 047` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
