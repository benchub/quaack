# Case 046: timestamptz cast to date, no index.

**Category:** `both`, rewrite + new index.

**Exercises:** cast on the column; expression index impossible: timestamptz to date isn't immutable; LLM expression-index DDL fails and feeds llm-index-refine; range rewrite depends on TimeZone (inventory).

## Setup.

Case 001's `customers` and `orders`. Nothing indexes `created_at`.

## Slow query (`slow.sql`).

One day's orders. The cast hides `created_at` from any index, and there's no index on it anyway.

## Expected result.

- **Rewrite:** a half-open range in the session's time zone. Stated assumption: the run server's `TimeZone` matches production's, which run-server checks.
- **Index:** `orders (created_at)`.
- An expression index on `(created_at::date)` can't be built, because the cast depends on `TimeZone`. If the LLM proposes it, the DDL fails, and that should feed llm-index-refine rather than crash the run.

## Proof.

`ruby e2e/verify.rb 046` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
