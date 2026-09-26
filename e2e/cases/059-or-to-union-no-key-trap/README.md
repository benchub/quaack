# Case 059: OR to UNION without a unique key in the output.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** UNION collapses duplicate rows; select list with no unique key; duplicates fixture (step 9, S3).

## Setup.

Case 001's `customers` and `orders`. Each customer has several shipped orders.

## Slow query (`slow.sql`).

Order statuses for one customer, or any cancelled order. The select list has no unique key, so the original legitimately returns duplicate rows.

## Expected result.

QUAACK must reject the `UNION` rewrite, which collapses the customer's eight identical `(4242, shipped)` rows into one. Case 001's `UNION` is safe only because its output includes `orders.id`.

## Proof.

`ruby e2e/verify.rb 059` checks the claims above. The measured table is in `results.md`.
