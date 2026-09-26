# Case 011: Time range on an append-only table.

**Category:** `index`, new index only.

**Exercises:** BRIN candidate from a well-correlated range column (5a-1 rule 7, 5a-5); correlation sent as a derived scalar (3f); GROUP BY over the range.

## Setup.

`readings` has a million rows, inserted in `recorded_at` order. Only the primary key is indexed.

## Slow query (`slow.sql`).

Per-sensor totals for one hour. With no index on `recorded_at`, Postgres scans every row.

## Expected result.

A BRIN index on `recorded_at`: generator one emits it because the range column's correlation is 1 and the table is large. A btree on `recorded_at` also wins and may touch slightly fewer blocks. The ranking picks by total blocks, and the report should show BRIN's much smaller built size either way.

## Proof.

`ruby e2e/verify.rb 011` checks the claims above. The measured table is in `results.md`.
