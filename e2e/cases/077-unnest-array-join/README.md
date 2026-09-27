# Case 077: Join to unnest(ARRAY[...]).

**Category:** `index`, new index only.

**Exercises:** function in FROM (unnest); ARRAY[...] constructor; join to a function's rows; t.* in the select list.

## Setup.

`products` has 400,000 rows and no index on `sku`. The last SKU in the list doesn't exist.

## Slow query (`slow.sql`).

Look up a cart's SKUs, passed as one array.

## Expected result.

`products (sku)`, probed once per array element.

## Proof.

`ruby e2e/verify.rb 077` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
