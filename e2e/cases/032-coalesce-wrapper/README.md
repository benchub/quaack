# Case 032: COALESCE around an indexed column.

**Category:** `rewrite`, rewrite only.

**Exercises:** COALESCE on the column; literal-dependent rewrite; nullable column (NULL fixtures, S2).

## Setup.

`tasks` has 500,000 rows. `status` is indexed and NULL for 4% of rows. No row has the status `'new'`.

## Slow query (`slow.sql`).

The UI treats a NULL status as `'new'`, so the query wraps the column in `COALESCE`. That hides it from the index.

## Expected result.

`status = 'blocked'`. Stated assumption: the literal isn't `'new'`, the `COALESCE` default. For `'new'` the original would also return the NULL rows. The rewrite is right for every literal set here, but step 9 or 10 should test the default value itself.

## Proof.

`ruby e2e/verify.rb 032` checks the claims above. The measured table is in `results.md`.
