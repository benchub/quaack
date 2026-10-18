# date_cast_to_range.

This rule rewrites a test of a timestamp column cast to a date, such as `created_at::date = $1`, into a range on the column itself.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

`ts::date` is the day `ts` falls on. So `ts::date = d` holds exactly when `ts` is at or after midnight of `d` and before midnight of the next day. The rule writes that as `ts >= d AND ts < d + 1`, with `d` cast to `date`. The other comparisons work the same way:

| Before | After |
| --- | --- |
| `ts::date = d` | `ts >= d AND ts < d + 1` |
| `ts::date >= d` | `ts >= d` |
| `ts::date > d` | `ts >= d + 1` |
| `ts::date < d` | `ts < d` |
| `ts::date <= d` | `ts < d + 1` |
| `ts::date BETWEEN d1 AND d2` | `ts >= d1 AND ts < d2 + 1` |

The cast can be on either side, as in `d < ts::date`, and it can be written `ts::date`, `CAST(ts AS date)`, or `date(ts)`. The column must be of type `timestamp` or `timestamptz`, and a column of a table in the same `SELECT`'s `FROM`: `t.ts`, or a bare column that exactly one of those tables has, when every item of that `FROM` is a table. For a `timestamptz`, both the cast and the comparison with a date read the session's `TimeZone`, so they find the same midnights, on days that change to or from daylight saving time too. When `ts` or `d` is NULL, both forms are NULL.

The comparison must be a top-level condition of a `WHERE` or of an inner join's `ON`, in any `SELECT` of the query. The rule rewrites every comparison it can in one rewrite.

QUAACK replaces each constant with a placeholder before any rule runs. Thus the rule can't read the day. It asks the literal oracle whether the day is a finite date, and whether it and the day after it can be a `timestamp` and a `timestamptz`, and the oracle answers yes or no. Otherwise the rewrite could fail where the original doesn't, as `d + 1` does on the last date Postgres has. The literal sets keep such a placeholder at its slow literal in every set, since they only pick values for a placeholder that is compared with a table column, not with a cast of one. Thus every set runs the rewrite with the value the oracle saw.

The rule does not change these:

- A column of type `date`, `text`, or a domain, or an expression on the column, such as `(ts + interval '1 hour')::date`.
- A day that isn't a placeholder, bare or cast to `date`, such as `'2025-03-09'::timestamp` (which compares as a timestamp), or an expression like `$1::date + 1`.
- A day that is `infinity`, `-infinity`, or so late that its next day isn't a `timestamp`.
- `<>`, `NOT BETWEEN`, or `BETWEEN SYMMETRIC`, or an operator that names a schema other than `pg_catalog`.
- A comparison under an `OR` or a `NOT`, in a select list, or in the `ON` of an outer join.
- A cast of a column of an outer query, in a subquery.
- A function named `date` in another schema, written with its schema.

## Why it can be faster.

A btree index on `ts` holds the column's values in order. Postgres can use it for a range like `ts >= d AND ts < d + 1`, and read only that day's rows. It can't use it for `ts::date = d`, because the index holds `ts`, not `ts::date`. Postgres reads every row instead and casts each one. An index on the expression `(ts::date)` would help, but Postgres can't build one on a `timestamptz` column, since that cast depends on the session's `TimeZone`. The range needs only a plain index on the column.

## What it rests on.

Nothing. The rewrite holds by what a cast to `date` means, so the rule needs no fact from the catalog, and it states no assumptions.

## Example.

This query lists one course's submissions made on one day. The range on `submitted_at` gives the same rows, and an index on `submitted_at` can serve it.

QUAACK replaces each constant with a placeholder, such as `$1`, before any rule runs. Thus the example shows the constants as placeholders. Here `$2` is `'2025-03-09'`. The rule made this "after" on Postgres 18, from these tables. They're the tables the other rules' pages use, with a `submitted_at` column added to `submissions`, since none of them has a timestamp:

```sql
CREATE TABLE public.users (id bigint PRIMARY KEY, name text, workflow_state text NOT NULL);
CREATE TABLE public.courses (id bigint PRIMARY KEY, name text, workflow_state text NOT NULL);
CREATE TABLE public.enrollments (
  id bigint PRIMARY KEY,
  user_id bigint NOT NULL REFERENCES public.users,
  course_id bigint NOT NULL REFERENCES public.courses,
  type text NOT NULL,
  workflow_state text NOT NULL
);
CREATE TABLE public.assignments (
  id bigint PRIMARY KEY,
  context_id bigint NOT NULL,
  context_type text NOT NULL,
  title text,
  workflow_state text NOT NULL
);
CREATE TABLE public.submissions (
  id bigint PRIMARY KEY,
  assignment_id bigint NOT NULL REFERENCES public.assignments,
  user_id bigint NOT NULL REFERENCES public.users,
  course_id bigint REFERENCES public.courses,
  workflow_state text NOT NULL,
  score numeric,
  submitted_at timestamptz
);
```

Before:

```sql
SELECT submissions.*
FROM public.submissions
WHERE
  submissions.course_id = $1
  AND submissions.submitted_at::date = $2
```

After:

```sql
SELECT submissions.*
FROM public.submissions
WHERE
  submissions.course_id = $1
  AND submissions.submitted_at >= $2::date
  AND submissions.submitted_at < ($2::date + 1)
```
