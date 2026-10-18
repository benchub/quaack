# Case 107: Paid orders counted per user.

**Category:** `rewrite`, rewrite only.

**Exercises:** GROUP BY a key over a has-many join; aggregate before the join; hash aggregate that spills to temp files (blocks-metric); uniqueness assumption (assumption-check).

## Setup.

A `users` table of 120,000 rows, each with a short profile, and an `orders` table of 3,000,000 rows. The first 100,000 users have 30 orders each. Each user's orders share one status: 75,000 users have only paid orders, and 25,000 only refunded ones. There's no index but the primary keys.

## Slow query (`slow.sql`).

A count of each user's paid orders, as Rails writes `User.joins(:orders).where(orders: { status: "paid" }).group(:id, :email, :name).count`. Postgres joins first, so 2,250,000 paid orders come out of the join, each with its user's email and name. It then groups them by user. The aggregate's hash table holds 75,000 groups with those text columns, and at the default `work_mem` it spills to temp files.

## Expected result.

The rewrite that the transform rule `aggregate_before_join` makes (`fast.sql`). It counts the paid orders of each `user_id` in a derived table, then joins the 75,000 counts to `users`. It states `users.id` unique and not null. The derived table's hash holds only a `bigint` and a count for each group, so it fits in memory. The rewrite reads the same shared blocks and writes no temp files, about 11% fewer total blocks on the slow literals. The refunded set's original plan spills more, so the rewrite wins by more. With no order of the status, there's nothing to group, and the two read the same blocks.

## Proof.

`ruby e2e/verify.rb 107` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
