# Minor mismatches in float values.

A QUAACK report may say a rewrite was dropped "because of minor mismatches in float values". This page says what that means, and what you can do about it.

## What happened.

QUAACK runs the original query and each rewrite that passed its tests on made-up data on the real data too, and drops any rewrite whose results differ from the original's (see [DESIGN.md's result comparison](../DESIGN.md#result-comparison-result-comparison)). On the real data it keeps no row values, only a fingerprint of each row. A fingerprint rounds each `float4` and `float8` value to eight significant digits, so values that differ only past that compare equal.

Floating-point arithmetic isn't exact, and the order of the work changes the last digits. `avg`, `sum`, `stddev`, and the like over a `float8` column add the rows in whatever order the plan reads them. Two plans, or two runs of one plan in parallel, can then return `0.30000000000000004` and `0.3` for one result. Usually both round to the same eight digits. But when the true value sits right on a rounding boundary, one rounds up and the other down, and the fingerprints differ. QUAACK can't tell that from a real difference, since it kept only the fingerprints, so it drops the rewrite. It never lets a wrong rewrite through this way. It only drops a good one.

When that happens, QUAACK looks again with every float value rounded to five significant digits. If the results then match, the report says the rewrite failed on minor mismatches in float values. If they still differ, the report keeps its usual words.

The same thing can stop QUAACK comparing results at all. It runs the original query twice to learn whether its order or its `LIMIT` cut is stable, and two runs that add rows in a different order can disagree in the last digit too.

## What you can do.

Write the query so its float outputs don't carry digits the app doesn't need. Then the original and the rewrite return the same values, and QUAACK can compare them. For example:

- Round the output: `SELECT user_id, round(avg(score)::numeric, 6) AS score FROM ratings GROUP BY user_id`.
- Cast it to a fixed precision: `SELECT user_id, avg(score)::numeric(12,4) AS score FROM ratings GROUP BY user_id`.
- Store the column as `numeric` instead of `float8`. `numeric` arithmetic is exact, so its sums don't depend on the order of the rows.
- Compare in the app at a tolerance it cares about, and have the query return only what it needs for that.

Each of these changes the query's output. It only fits when the app doesn't need the full float precision. Most apps that show an average, a rate, or a score don't.

Then run QUAACK again on the changed query.
