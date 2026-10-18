# Case 106: Dashboard count of distinct users.

**Category:** `rewrite`, rewrite only.

**Exercises:** count(DISTINCT) per group; SELECT DISTINCT that can hash; sort that spills to temp files (blocks-metric).

## Setup.

One `events` table of 1,500,000 rows: 40 courses, 3,000 users, and five kinds of event, three of them page views. Each (course, user) pair repeats many times. Every 97th event has no user. There's no index but the primary key.

## Slow query (`slow.sql`).

A course dashboard's count of the distinct users who viewed a page in each course, as Rails writes `Event.where(kind: "page_view").group(:course_id).distinct.count(:user_id)`, with an alias. Postgres can't hash a `count(DISTINCT)`. It sorts the 900,000 matching rows by course and user, and at the default `work_mem` that sort spills to temp files.

## Expected result.

The count over a `SELECT DISTINCT` of the course and the user (`fast.sql`), which the transform rule `count_distinct_to_subquery` makes. It states no assumption. Postgres hashes the distinct pairs, at most 72,000, in memory, so the rewrite reads the same shared blocks and writes no temp files, about 29% fewer total blocks on the slow literals. Submissions are fewer, so their sort spills less, and the rewrite wins by less. With no event of the kind, there's nothing to sort, and the two read the same blocks.

## Proof.

`ruby e2e/verify.rb 106` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
