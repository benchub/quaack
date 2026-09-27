# Case 099: Join to a VALUES list.

**Category:** `index`, new index only.

**Exercises:** VALUES in FROM with a column alias list; arithmetic in the select list.

## Setup.

Case 077's `products`, with no index on `sku`.

## Slow query (`slow.sql`).

Price a cart given as a `VALUES` list.

## Expected result.

`products (sku)`, probed once per row of the list.

## Proof.

`ruby e2e/verify.rb 099` checks the claims above. The measured table is in `results.md`.
