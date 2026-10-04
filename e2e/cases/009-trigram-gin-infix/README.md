# Case 009: Infix ILIKE search.

**Category:** `index`, new index only.

**Exercises:** GIN candidate set aside untested by HypoPG (index-dedupe); trigram operator class (llm-index-ideas); built and measured anyway in measurement-setup; leading-wildcard shape (redact).

## Setup.

`contacts` has 300,000 rows, and `pg_trgm` is installed. Each name ends in a hex tag.

## Slow query (`slow.sql`).

Search box: names containing a fragment anywhere. No btree can serve an infix `ILIKE`.

## Expected result.

A trigram GIN index on `full_name`. HypoPG can't model GIN, so index-dedupe sets it aside untested. measurement-setup still builds it, and baseline and candidate-runs measure it, and the report says it wasn't tested in index-search.

## Proof.

`ruby e2e/verify.rb 009` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
