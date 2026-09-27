# Case 089: ARRAY(SELECT ...) per row.

**Category:** `index`, new index only.

**Exercises:** ARRAY(SELECT ...) subquery; correlated subquery with ORDER BY; IN list on the primary key.

## Setup.

Case 088's `articles`, plus 600,000 `comments`, two per article. Nothing indexes `comments.article_id`.

## Slow query (`slow.sql`).

Three articles with their comments gathered into an array. Each `ARRAY(SELECT ...)` scans all the comments.

## Expected result.

`comments (article_id)`.

## Proof.

`ruby e2e/verify.rb 089` checks the claims above. The measured table is in `results.md`.
