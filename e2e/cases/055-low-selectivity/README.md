# Case 055: Filter that matches most of the table.

**Category:** `index`, new index only.

**Exercises:** index the planner declines to use (index-test); covering index turns it into an index-only scan; top-MCV literal.

## Setup.

Case 001's `customers` and `orders`. 80% of orders are shipped.

## Slow query (`slow.sql`).

The total of shipped orders. It reads 80% of the table, and a sequential scan reads all of it.

## Expected result.

`orders (status, total_cents)`: an index-only scan over an index much narrower than the table, so it wins even at 80% selectivity. It's the likely LLM proposal (llm-index-ideas), or generator one's candidate with `total_cents` moved from `INCLUDE` into the key.

When this case was measured, two neighbors behaved differently:
- Generator one's own `orders (status) INCLUDE (total_cents)` went unused for `'shipped'`, although it would give the same scan.
- A plain `orders (status)` also goes unused for a value this common.
index-test should record both as unused. A partial index, `(total_cents) WHERE status = 'shipped'`, also wins on the slow literal (398 blocks), since `status` is low-cardinality. It doesn't help the rare-status set.

## Proof.

`ruby e2e/verify.rb 055` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
