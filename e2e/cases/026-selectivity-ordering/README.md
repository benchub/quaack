# Case 026: Two equality columns, the unselective one indexed.

**Category:** `index`, new index only.

**Exercises:** equality columns ranked by selectivity (5a-1); negative n_distinct converted to a count (5a-1); ORDER BY after the equality columns.

## Setup.

`messages` has 600,000 rows: 10 tenants and 50,000 threads. Only `tenant_id` is indexed, and it matches 10% of the table.

## Slow query (`slow.sql`).

A thread's messages. The tenant index is nearly useless, so Postgres scans the table.

## Expected result.

`messages (thread_id, tenant_id, sent_at)`: the most selective equality column first, then the other one, then the `ORDER BY` column.

## Proof.

`ruby e2e/verify.rb 026` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
