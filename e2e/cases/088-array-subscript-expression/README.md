# Case 088: Filter on an array element.

**Category:** `index`, new index only.

**Exercises:** array subscript; array slice; expression index on an array element (llm-index-ideas); text[] column statistics (classify).

## Setup.

`articles` has 300,000 rows with a `text[]` of tags. Only the primary key is indexed.

## Slow query (`slow.sql`).

Articles whose primary tag is `postgres`.

## Expected result.

An expression index on `(tags[1])`, from the LLM generator.

## Proof.

`ruby e2e/verify.rb 088` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
