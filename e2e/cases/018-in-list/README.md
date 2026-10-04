# Case 018: IN list on an unindexed column.

**Category:** `index`, new index only.

**Exercises:** IN list atom; IN list keeps its length in the worst-case and typical literals (literals).

## Setup.

`stock_moves` has 500,000 rows for 20,000 products. Only the primary key is indexed.

## Slow query (`slow.sql`).

Net stock movement for a handful of products. The table is scanned for 125 rows.

## Expected result.

`stock_moves (product_id)`.

## Proof.

`ruby e2e/verify.rb 018` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
