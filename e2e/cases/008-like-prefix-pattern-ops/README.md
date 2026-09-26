# Case 008: Prefix LIKE under a non-C collation.

**Category:** `index`, new index only.

**Exercises:** LIKE with a trailing wildcard (3g shape); operator class text_pattern_ops (5a-5); dedupe must count the operator class as part of the key (5a-3).

## Setup.

`products` has 400,000 rows with an ordinary index on `sku`. The database collation is `en_US.utf8`, as in the stock image.

## Slow query (`slow.sql`).

SKU search by prefix. Under a non-C collation, the ordinary index can't serve `LIKE 'ABX-00123%'`, so Postgres scans the table.

## Expected result.

`products (sku text_pattern_ops)`, from the LLM generator. 5a-3 must not drop it as a duplicate of `products_sku_idx`: same column, different operator class.

## Proof.

`ruby e2e/verify.rb 008` checks the claims above. The measured table is in `results.md`.
