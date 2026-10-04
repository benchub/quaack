# Case 006: Rare status value, sorted.

**Category:** `index`, new index only.

**Exercises:** partial index on a low-cardinality column (llm-index-ideas, classify); MCV values sent for a low-cardinality column; top-MCV worst-case literal (literals); partial-index tag in the report.

## Setup.

`jobs` has 500,000 rows. `status` has three values, so it's low-cardinality (classify), and its MCV values go to the LLM. Nothing is indexed but the primary key.

## Slow query (`slow.sql`).

The oldest failed jobs. Postgres reads the whole table and top-N sorts the 5,000 failures.

## Expected result.

A partial index `jobs (queued_at, id) WHERE status = 'failed'`. The mechanical generators may instead offer `jobs (status, queued_at)`, which also wins but is far larger. The partial index must carry the tag saying it only works when `'failed'` is a constant in the application's SQL.

On the worst-case literal (`'done'`, the top MCV), the partial index isn't used, and the plan is no worse, so minimax still holds.

## Proof.

`ruby e2e/verify.rb 006` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
