# The original query's own two runs differed.

A QUAACK report may say a test of a rewrite ended without comparing results "because the original query returned different rows on two runs QUAACK made of it over the same data, which differed only in how they broke ties". This page says what those two runs are, what makes them differ, why that says nothing about the rewrite, and what you can do about it.

## What the two runs are.

Both runs are of your original query, not of the rewrite, and QUAACK makes them itself. They read the same data, inside the test.

A rewrite is right when it returns the rows the original query could return. When the query's `ORDER BY` doesn't give a total order, such as `ORDER BY min(created_at)` where two groups can share a time, Postgres may put tied rows in any order, and a right rewrite may put them in another. So, for the comparison only, QUAACK adds a tiebreaker to the end of the `ORDER BY`, such as the table's primary key or every output column, and runs the original twice: once with the tiebreaker ascending, and once with it descending. The two runs show which rows are tied and where each tied group starts and ends, so QUAACK can then accept a rewrite that orders the ties its own way (see [DESIGN.md's fixture compare](../DESIGN.md#fixture-compare-compare-results)).

The tiebreaker only reorders tied rows. With no `LIMIT` or `OFFSET` to cut a tied group, the two runs must hold the same rows, in some order. When they don't, the original query itself gave different rows on two runs over the same data, and QUAACK stops.

QUAACK makes these runs on each set of test data: made-up data, data the LLM wrote to break the rewrite, and the real data. So the report says which one it was.

## What makes them differ.

Changing the tiebreaker's direction changes the query, so Postgres may plan it differently: sort the other way, pick another join order, or read a table in another order. Then the rows reach each aggregate in a different order. Most queries don't care, but these can:

- **A float aggregate whose result depends on the order of its rows.** `sum`, `avg`, `stddev`, and the like over a `float4` or `float8` column add the rows in whatever order they arrive, and floating-point addition isn't exact. Usually that changes only the last digit or two, and QUAACK counts two floats within one part in a billion of each other as equal, so those runs agree. But values of very different sizes that cancel out change far more. In `float8`, `1e20 + 1 - 1e20` is `0`, while `1e20 - 1e20 + 1` is `1`. So `avg(amount)` over the rows `1e20`, `1`, and `-1e20` is `0` in one order and about `0.333` in another. Real data rarely holds values like those, but the LLM's test data is written to break things, and it can. The difference then shows up in the output column, or, when the aggregate sits in a `HAVING` such as `HAVING sum(amount) > 0`, as a group that one run keeps and the other drops.
- **A float that lands near a rounding boundary, on the real data.** On the real data, QUAACK keeps only a fingerprint of each row, with each float rounded to eight significant digits, so even a last-digit difference can split two values that agree. QUAACK then looks again, and when the runs differed only that way, the report says so with its own words instead, and links to [minor mismatches in float values](float-values.md).
- **A function that returns something different each time, but isn't marked `VOLATILE`.** QUAACK refuses a query that calls a volatile function, such as `random()` or `clock_timestamp()`, before it tests anything, and it fixes the clock that `now()`, `current_date`, and the like read. But it trusts how each function is declared. A function of your own declared `STABLE` or `IMMUTABLE` that calls `random()` can still return something different on each run.
- **A clock QUAACK couldn't fix.** A clock word such as `'today'` that QUAACK can't see as a date, such as one passed to a function that takes a date, still reads the clock. On the real data each run is its own transaction, so the two runs can read different times, and a query that filters on that time can keep different rows.

An aggregate whose value follows the order of its rows by design, such as `array_agg` or `string_agg` without an `ORDER BY` of its own, is checked in its own way, and the report names that check instead.

## Why it says nothing about the rewrite.

QUAACK checks a rewrite by asking whether its results are ones the original query could have returned on that data. When the original gives different rows on two runs over the same data, there's no one answer to hold the rewrite to, so QUAACK stops before it checks the rewrite's results on that data. The rewrite may be right or wrong. QUAACK still drops it, since it never recommends a rewrite it couldn't check.

## What you can do.

Write the query so it gives the same rows whatever order Postgres reads them in. Then QUAACK can compare its results. For example:

- Round the float output: `SELECT user_id, round(avg(score)::numeric, 6) AS score FROM ratings GROUP BY user_id`. Rounding doesn't help with values that cancel, since the difference there is far bigger than the rounding.
- Add up in `numeric` instead of `float8`: `SELECT user_id, avg(score::numeric) AS score FROM ratings GROUP BY user_id`. `numeric` arithmetic is exact, so its sums don't depend on the order of the rows. That handles values that cancel too.
- Store the column as `numeric` instead of `float8`, for the same reason.
- Declare a function that can return something different each time as `VOLATILE`. QUAACK then refuses the query outright, and says why, instead of testing it.
- Write a clock word the way QUAACK can fix it, such as `'today'::date` or `current_date`.

Each of the first three changes the query's output a little. It only fits when the app doesn't need the full float precision.

Then run QUAACK again on the changed query.
