# Case 010: jsonb containment filter.

**Category:** `index`, new index only.

**Exercises:** jsonb @> operator; GIN with jsonb_path_ops, set aside untested (5a-3); json values never sent, only frequencies (3f).

## Setup.

`webhooks` has 400,000 rows with a `jsonb` payload. One in 500 is a refund.

## Slow query (`slow.sql`).

Find refund webhooks. `@>` on an unindexed `jsonb` column means a full scan.

## Expected result.

A GIN index on `payload` with `jsonb_path_ops`. Like case 009, it's set aside untested in 5a and measured in step 12.

## Notes.

A btree expression index on `(payload ->> 'type')` would need the query to change, so it isn't a fix here.

## Proof.

`ruby e2e/verify.rb 010` checks the claims above. The measured table is in `results.md`.
