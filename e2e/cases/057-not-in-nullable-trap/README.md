# Case 057: NOT IN to NOT EXISTS over a nullable column.

**Category:** `trap`, tempting rewrite that QUAACK must disprove.

**Exercises:** NOT IN with a NULL in the subquery; NULL fixtures disprove the rewrite (step 9, S2); unmet NOT NULL assumption (6b).

## Setup.

`employees` has 20,000 rows. The top 10 have no manager, so `manager_id` holds NULLs.

## Slow query (`slow.sql`).

Employees who manage nobody, written with `NOT IN`. Because the subquery returns NULLs, `NOT IN` is never true, and the original returns no rows at all. That's almost certainly a bug in the app, but QUAACK must keep the query's meaning.

## Expected result.

QUAACK must reject the tempting `NOT EXISTS` rewrite (`fast.sql`), which returns 499 rows. The stated assumption (`manager_id` is `NOT NULL`) fails 6b, so an LLM candidate is rejected there. An operator candidate only gets a warning, and then step 9's S2 scenario (NULLs in nullable columns) disproves it.

## Proof.

`ruby e2e/verify.rb 057` checks the claims above. The measured table is in `results.md`.
