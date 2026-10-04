# Case 072: FETCH FIRST ... WITH TIES.

**Category:** `index`, new index only.

**Exercises:** FETCH FIRST WITH TIES; ORDER BY that isn't a total order (fixture-compare tiebreaker); Sort under a Limit (index-from-plan).

## Setup.

`scores` has 600,000 rows for 20 games, with only 5,000 distinct scores, so ties are common.

## Slow query (`slow.sql`).

A game's top 10 including ties. Postgres sorts all 30,000 of the game's rows.

## Expected result.

`scores (game_id, score DESC)`. `WITH TIES` makes the row set exact even though the order within a tie isn't, so the proof compares multisets. fixture-compare would add a tiebreaker to both queries instead.

## Proof.

`ruby e2e/verify.rb 072` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
