# Case 048: Recursive CTE that walks every tree.

**Category:** `both`, rewrite + new index.

**Exercises:** WITH RECURSIVE; push the filter into the anchor; index on the recursive join key; IS NULL atom on a nullable parent key.

## Setup.

`categories` is a forest of 200,000 nodes under 2,000 roots. `parent_id` isn't indexed.

## Slow query (`slow.sql`).

One root's subtree. The CTE walks every tree in the forest, and the filter only applies at the end. Each level of the recursion hash-joins the whole table.

## Expected result.

- **Rewrite:** filter the anchor to the one root. `root_id` is copied unchanged down the recursion, so filtering at the anchor keeps exactly the same rows.
- **Index:** `categories (parent_id)`, so each level probes for children instead of scanning.
- The rewrite alone still scans the table once per level, and the index alone still walks the whole forest.

## Notes.

The "not a root" set proves both return nothing for a non-root id. It isn't a 3e set, so minimax doesn't judge it.

## Proof.

`ruby e2e/verify.rb 048` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
