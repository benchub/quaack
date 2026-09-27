# Case 088: Filter on an array element.

**Category:** `index`, new index only.

**Exercises:** array subscript; array slice; expression index on an array element (5a-5); text[] column statistics (3f).

## Setup.

`articles` has 300,000 rows with a `text[]` of tags. Only the primary key is indexed.

## Slow query (`slow.sql`).

Articles whose primary tag is `postgres`.

## Expected result.

An expression index on `(tags[1])`, from the LLM generator.

## Proof.

`ruby e2e/verify.rb 088` checks the claims above. The measured table is in `results.md`.
