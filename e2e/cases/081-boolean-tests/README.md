# Case 081: IS NOT TRUE, IS NOT NULL, and boolean and bit literals.

**Category:** `index`, new index only.

**Exercises:** IS NOT TRUE on a nullable boolean; IS NOT NULL; boolean literal; bit-string literal and operator.

## Setup.

`todos` has 500,000 rows for 2,000 assignees. `archived` is a nullable boolean. Nothing indexes `assignee_id`.

## Slow query (`slow.sql`).

Someone's open urgent todos with a due date. `archived IS NOT TRUE` keeps NULL as well as false.

## Expected result.

`todos (assignee_id)`. The boolean tests stay as filters.

## Proof.

`ruby e2e/verify.rb 081` checks the claims above. The measured table is in `results.md`.
