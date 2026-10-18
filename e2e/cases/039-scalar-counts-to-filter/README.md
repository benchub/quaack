# Case 039: Three scalar subqueries over one table.

**Category:** `rewrite`, rewrite only.

**Exercises:** uncorrelated scalar subqueries; aggregate FILTER; one pass instead of three.

## Setup.

Case 001's `customers` and `orders`. `status` isn't indexed.

## Slow query (`slow.sql`).

A status dashboard. Each scalar subquery scans the whole table, three scans in all.

## Expected result.

One scan with `count(*) FILTER (...)` per status.

## Rule.

The transform rule `scalar_aggregates_to_filter` makes this rewrite from `slow.sql`, as a one-row derived table of the `FILTER`ed counts that the select list reads, which scans the table once as `fast.sql` does.

## Proof.

`ruby e2e/verify.rb 039` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
