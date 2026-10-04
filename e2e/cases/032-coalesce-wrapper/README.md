# Case 032: COALESCE around an indexed column.

**Category:** `rewrite`, rewrite only.

**Exercises:** COALESCE on the column; literal-dependent rewrite; nullable column (NULL fixtures, S2).

## Setup.

`tasks` has 500,000 rows. `status` is indexed and NULL for 4% of rows. No row has the status `'new'`.

## Slow query (`slow.sql`).

The UI treats a NULL status as `'new'`, so the query wraps the column in `COALESCE`. That hides it from the index.

## Expected result.

`status = 'blocked'`. Stated assumption: the literal isn't `'new'`, the `COALESCE` default. For `'new'` the original would also return the NULL rows. The literal is compared with an expression, so literals keeps the slow literal in every set. The other sets here only prove equivalence, and rewrite-test or counterexamples should test the default value itself.

## Proof.

`ruby e2e/verify.rb 032` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
