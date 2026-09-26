# Case 069: Correlated float average.

**Category:** `rewrite`, rewrite only.

**Exercises:** float aggregates compared with a tolerance (9d); correlated subquery to a pre-aggregated join.

## Setup.

`samples` has 400,000 `double precision` values for 2,000 sensors. `sensor_id` and `batch` are indexed.

## Slow query (`slow.sql`).

Each recent sample's distance from its sensor's mean. The average is recomputed for every row.

## Expected result.

Pre-aggregate the averages once and join. Float sums can differ in the last bits when rows are added in a different order, so the comparison needs 9d's float tolerance. The proof compares each number to within a relative 1e-9.

## Proof.

`ruby e2e/verify.rb 069` checks the claims above. The measured table is in `results.md`.
