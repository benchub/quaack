# Case 049: Division on a column, with no useful index.

**Category:** `both`, rewrite + new index.

**Exercises:** arithmetic on the column; CHECK constraint as a stated assumption (6b); equality then range in a composite key (5a-1).

## Setup.

`charges` has 600,000 rows for 30 merchants. Only the primary key is indexed.

## Slow query (`slow.sql`).

One merchant's charges in a dollar bucket. Nothing is indexed, and the division would hide `amount_cents` from an index anyway.

## Expected result.

- **Rewrite:** a half-open range, as in case 033.
- **Index:** `charges (merchant_id, amount_cents)`.
- The index alone helps a little: it can seek on `merchant_id`, then it filters 20,000 rows. With the rewrite, it seeks straight to the range.

## Proof.

`ruby e2e/verify.rb 049` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
