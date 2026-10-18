# coalesce_comparison_split.

The rule splits a `COALESCE` of a column and a default, compared with a value, into a comparison of the column and a test for its `NULL`s.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule takes a condition of the form `COALESCE(t.c, $d) = $v`. It writes it as `(t.c = $v OR (t.c IS NULL AND COALESCE($d, t.c) = $v))`. A `<>` splits the same way, and the `COALESCE` may be on either side. The column is written `name.column`, or as a bare name when the `FROM` is just one table that has it. `$d` and `$v` are placeholders. Either may be cast, but a cast on `$d` must be to the column's own type. When `$d` isn't cast, the rule asks the literal oracle whether the `COALESCE` still has the column's type, since a number can widen it, as `0.5` makes an `integer` column's `COALESCE` a `numeric`.

When the column isn't `NULL`, both forms compare the column with `$v`. When it's `NULL`, both compare `$d` with `$v`. The new `COALESCE` holds the same arguments, swapped, so it has the original's type and collation. The rule needs the `COALESCE`'s type to be the column's own, so that `t.c = $v` uses the same operator as the original.

The two forms can differ in one way. Where one gives `NULL`, the other can give `false`. A condition of a `WHERE`, or of an inner join's `ON`, drops a row in both cases. So the rule takes a condition only when it's one of the conditions that such a `WHERE` or `ON` joins with `AND`. That holds in any `SELECT` at any depth. The rule gives one rewrite for each condition it can split.

The rule refuses:

- a condition under `NOT`, `OR`, or `IS NULL`, or in an outer join's `ON`, where `NULL` and `false` can differ,
- any other operator, such as `<`, `IS NOT DISTINCT FROM`, or `= ANY`, and an operator with a schema,
- a `COALESCE` with more than two arguments, or whose arguments aren't the column and then a placeholder,
- a default placeholder that the query uses anywhere else, since that use could give it another type,
- a default cast to a type other than the column's own, or an uncast default that gives the `COALESCE` another type, and
- a column whose table the `SELECT`'s `FROM` doesn't name once as a plain table, such as one with column aliases, a CTE, or an outer query's table.

These cases are unsupported in v1:

- a default that is a constant QUAACK didn't turn into a placeholder, or an expression, and
- a `COALESCE` in a `HAVING`, a `CASE`, or a function call.

## Why it can be faster.

An index on a column holds the column's values, not the values of an expression over it. So Postgres can't use an index on `score` to find rows where `COALESCE(score, 0) = 0`, and it reads every row of the table instead. In the split form, Postgres knows `$d` and `$v` once the query runs, so it works out `COALESCE($d, t.c) = $v` ahead of time, since a `COALESCE` that starts with a known value is that value. What's left is `t.c = $v`, or `t.c = $v OR t.c IS NULL`. An index serves both, and Postgres can combine two index scans for the `OR`.

## What it rests on.

Nothing. The split returns the same rows for any data and any values, so the rule states no assumption.

## Example.

This query finds an assignment's submissions with a score of 0, counting an ungraded one as 0, as Rails writes `Submission.where(assignment_id: 42).where("COALESCE(score, 0) = 0")`, with a shorter select list. QUAACK replaces each constant with a placeholder, such as `$1`, before any rule runs. Thus the example shows the constants as placeholders. The rule made this "after" on Postgres 18, from these tables:

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
  score numeric
);
```

Before:

```sql
SELECT submissions.id, submissions.user_id
FROM public.submissions
WHERE submissions.assignment_id = $1 AND COALESCE(submissions.score, $2) = $3
```

After:

```sql
SELECT submissions.id, submissions.user_id
FROM public.submissions
WHERE submissions.assignment_id = $1
  AND (submissions.score = $3 OR (submissions.score IS NULL AND COALESCE($2, submissions.score) = $3))
```
