# Case 019: Skewed tenant sizes.

**Category:** `index`, new index only.

**Exercises:** top MCV as the worst-case literal (3e); index that helps the slow literal and is no worse for the top MCV (14b); rank by worst-case reduction (5a-7).

## Setup.

`audit_log` has 500,000 rows. Tenant 1 owns 60% of them.

## Slow query (`slow.sql`).

A small tenant's activity summary. Without an index, it costs a full scan, the same as the giant tenant's.

## Expected result.

`audit_log (tenant_id)`. For the worst-case literal, tenant 1, the planner keeps its sequential scan, so the index is no worse there, and minimax (14b) accepts it.

## Proof.

`ruby e2e/verify.rb 019` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
