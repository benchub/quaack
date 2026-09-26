# Case 009: Infix ILIKE search.

**Category:** `index`, new index only.

**Exercises:** GIN candidate set aside untested by HypoPG (5a-3); trigram operator class (5a-5); built and measured anyway in step 12; leading-wildcard shape (3g).

## Setup.

`contacts` has 300,000 rows, and `pg_trgm` is installed. Each name ends in a hex tag.

## Slow query (`slow.sql`).

Search box: names containing a fragment anywhere. No btree can serve an infix `ILIKE`.

## Expected result.

A trigram GIN index on `full_name`. HypoPG can't model GIN, so 5a-3 sets it aside untested. Step 12 still builds it, and steps 13 and 14 measure it, and the report says it wasn't tested in 5a.

## Proof.

`ruby e2e/verify.rb 009` checks the claims above. The measured table is in `results.md`.
