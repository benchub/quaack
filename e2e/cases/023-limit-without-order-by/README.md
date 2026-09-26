# Case 023: LIMIT with no ORDER BY.

**Category:** `index`, new index only.

**Exercises:** LIMIT with no ORDER BY: subset comparison (9d); two equality columns.

## Setup.

`invoices` has 500,000 rows for 5,000 customers. About 14 of each customer's invoices are overdue.

## Slow query (`slow.sql`).

Any five overdue invoices, for a reminder email. With no index, the scan runs until it finds five.

## Expected result.

`invoices (customer_id, status)`. The query has no `ORDER BY`, so the indexed plan may return different rows. 9d only asks for the same count, all from the unlimited result, and so does this proof.

## Proof.

`ruby e2e/verify.rb 023` checks the claims above. The measured table is in `results.md`.
