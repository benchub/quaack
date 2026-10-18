# Case 102: count over a list query that still sorts.

**Category:** `rewrite`, rewrite only.

**Exercises:** count(*) FROM (... ORDER BY ...); subquery ORDER BY with no LIMIT blocks flattening; index-only count.

## Setup.

`users` and `posts`, 400 posts per user, written round-robin so each user's posts sit on 400 different heap pages. `posts.user_id` is indexed.

## Slow query (`slow.sql`).

An app counts a user's posts, to show how many pages of them there are, by wrapping the list's own SQL in `SELECT count(*) FROM (...) subquery_for_count`. The list's `ORDER BY` comes along. Rails' own `count` drops the `ORDER BY` when it builds such a subquery (`build_count_subquery` in `ActiveRecord::Calculations`), so this is the shape of an app's own count of a list's SQL.

Postgres won't merge a subquery that sorts into the query that reads it. So it reads all 400 rows from the heap for `created_at`, sorts them, and counts them: 409 blocks.

## Expected result.

The same query without the subquery's `ORDER BY`. The count doesn't depend on the order of the rows. Without the sort, Postgres merges the subquery into the count and counts the entries of `posts_user_id` with an index-only scan: 7 blocks on the slow literals.

The transform rule `subquery_order_removal` makes this rewrite from `slow.sql`, with no assumption.

## Proof.

`ruby e2e/verify.rb 102` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
