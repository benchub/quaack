# Case 103: DISTINCT over a to-one join.

**Category:** `rewrite`, rewrite only.

**Exercises:** Rails .distinct over a to-one join; DISTINCT that a unique key makes redundant; uniqueness assumption (assumption-check); sort that spills to temp files (blocks-metric).

## Setup.

Case 001's `customers` and `orders`.

## Slow query (`slow.sql`).

An admin order search, as Rails writes `Order.joins(:customer).select("orders.*, customers.email AS customer_email").where(...).distinct`. The search scope always calls `.distinct`, because some of its filters join a has-many association. This one joins only the order's customer, so no row can repeat. Postgres still sorts all 100,000 matching rows by every selected column to find duplicates, and at the default `work_mem` that sort spills to temp files.

## Expected result.

The same query without `DISTINCT` (`fast.sql`), which the transform rule `distinct_key_removal` makes. Stated assumptions: `orders.id` is unique and not null, and `customers.id` is unique. So each order joins at most one customer, and the selected `orders.id` tells every row apart. The rewrite reads the same shared blocks and writes no temp files, about 29% fewer total blocks on the slow literals. Pending orders are few enough to sort in memory, so there the two tie. With no customer in the region, there's nothing to sort, and the two read about the same blocks.

## Proof.

`ruby e2e/verify.rb 103` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
