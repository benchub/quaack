# Case 007: Case-insensitive lookup.

**Category:** `index`, new index only.

**Exercises:** expression index (5a-5); unique index the planner can't use; PII column: MCVs withheld (3f).

## Setup.

`users` has 300,000 rows. `email` is unique, but a third of the addresses are stored with capitals.

## Slow query (`slow.sql`).

Login lookup by email, ignoring case. The unique index on `email` can't serve `lower(email)`, so Postgres reads the whole table.

## Expected result.

An expression index on `users (lower(email))`. Only the LLM generator proposes expression indexes.

## Proof.

`ruby e2e/verify.rb 007` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
