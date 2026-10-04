# Case 023: LIMIT with no ORDER BY.

**Category:** `index`, new index only.

**Exercises:** LIMIT with no ORDER BY: subset comparison (fixture-compare); two equality columns; non-default planner setting from the plan's SETTINGS (inventory and run-server).

## Setup.

`invoices` has 500,000 rows for 5,000 customers. About 14 of each customer's invoices are overdue.

## Slow query (`slow.sql`).

Any five overdue invoices, for a reminder email. With no index, the scan runs until it finds five.

## Expected result.

`invoices (customer_id, status)`. The query has no `ORDER BY`, so the indexed plan may return different rows. fixture-compare only asks for the same count, all from the unlimited result, and so does this proof.

## Notes.

The production plan ran with `max_parallel_workers_per_gather = 0`, which `case.json` records as `settings`. inventory should pick it up from the plan's `SETTINGS`, and run-server should require the run server to match. With parallel workers, a scan that stops at the `LIMIT` touches a different number of blocks each run, depending on how the workers race. README 13 would mark such a literal unstable.

## Proof.

`ruby e2e/verify.rb 023` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
