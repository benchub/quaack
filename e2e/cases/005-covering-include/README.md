# Case 005: Aggregate that could be an index-only scan.

**Category:** `index`, new index only.

**Exercises:** INCLUDE columns for an index-only scan (5a-1); aggregate over one account's rows.

## Setup.

`payments` has 500,000 wide rows for 200 merchants. `merchant_id` is indexed. The table is vacuumed, so its visibility map is set.

## Slow query (`slow.sql`).

A merchant's payment total. The index finds 2,500 rows, and each one costs a heap fetch on a different page.

## Expected result.

`payments (merchant_id) INCLUDE (amount_cents)`, from 5a-1's rule that adds the other select-list columns as `INCLUDE`. It turns the query into an index-only scan.

## Proof.

`ruby e2e/verify.rb 005` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
