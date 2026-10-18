# Case 105: Activity feed UNION of two tables.

**Category:** `rewrite`, rewrite only.

**Exercises:** activity feed: a UNION of two tables with a tag column; UNION that unique keys and distinct tags make redundant; uniqueness assumption (assumption-check); literal oracle on select-list placeholders that literals keeps slow; filter and LIMIT that reach each table's index only through UNION ALL.

## Setup.

`posts` has 200,000 rows and `comments` 400,000, spread evenly over 20 groups, with two comments on every post. No two rows of either table share a `created_at`. Each table has an index on `(group_id, created_at)` for the group feed.

## Slow query (`slow.sql`).

A group's activity feed: the newest 20 posts and comments, each tagged with its kind. The app builds the feed as a `UNION` of the two tables in a derived table, and filters and pages it outside. Postgres pushes the `group_id` filter into each arm, but `UNION` has to remove duplicates, so it reads all 30,000 of the group's rows from both tables, hashes them, and only then sorts for the first 20. That reads about 18,000 blocks.

## Expected result.

The same query with `UNION ALL` (`fast.sql`), which the transform rule `union_to_union_all` makes. Each arm selects its table's primary key, so it has no duplicates of its own, and the arms' tags, `'post'` and `'comment'`, differ, so no row of one arm equals a row of the other. Stated assumptions: `posts.id` and `comments.id` are each unique and not null. The tags rest on no catalog fact: the rule asks the literal oracle whether they differ, as the `UNION` compares them. literals keeps a select-list placeholder at its slow literal in every set, so `case.json` has no other literals picks; the `group_id` literal, compared with the derived table's column, and the `LIMIT` stay slow too. The other sets only prove the two queries return the same rows.

`UNION ALL` of plain arms is flattened into the outer query, so Postgres takes the filter and the `ORDER BY ... LIMIT` to each table, walks each `(group_id, created_at)` index backwards in a Merge Append, and stops after 20 rows. That's 22 blocks on the slow literals, against about 18,000. A longer page reads more of each index, and still wins by far. With no such group, both read only the indexes' first pages.

## Proof.

`ruby e2e/verify.rb 105` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
