# Case 017: Leaderboard with mixed sort directions.

**Category:** `index`, new index only.

**Exercises:** ORDER BY with mixed directions (5a-1 direction match); Sort under a Limit (5a-2); four-column key cap.

## Setup.

`scores` has 600,000 rows for 20 games. `game_id` is indexed.

## Slow query (`slow.sql`).

A game's top 10. Ties on `score` go to whoever got there first. Postgres fetches the game's 30,000 rows and sorts them.

## Expected result.

`scores (game_id, score DESC, achieved_at, id)`. The directions must match the `ORDER BY`, or the scan can't replace the sort.

## Proof.

`ruby e2e/verify.rb 017` checks the claims above. The measured table is in `results.md`.
