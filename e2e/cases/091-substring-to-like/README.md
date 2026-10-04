# Case 091: substring() prefix test.

**Category:** `rewrite`, rewrite only.

**Exercises:** substring(... FROM ... FOR ...); position(... IN ...); overlay(... PLACING ...); trim(BOTH / LEADING / TRAILING ...); literal-dependent rewrite.

## Setup.

`parts` has 400,000 rows, with `sku` indexed using `text_pattern_ops`.

## Slow query (`slow.sql`).

Parts in a SKU family, tested with `substring`. The function hides `sku` from its index.

## Expected result.

`sku LIKE 'ABX-001' || '%'`. Stated assumptions: the literal is exactly as long as the `FOR` length, and holds no `%` or `_`. A shorter literal would never equal the 7-character substring but would match as a prefix. literals keeps the slow literal for a placeholder compared with a function, so every literal set has 7 characters.

## Proof.

`ruby e2e/verify.rb 091` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
