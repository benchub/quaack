# count_to_exists.

This rule rewrites a count subquery that only asks whether any row matches, such as `(SELECT count(*) ...) > 0`, into `EXISTS`, or `NOT EXISTS` for `= 0`.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

A count is never NULL and never below 0. So `count > 0`, `count >= 1`, and `count <> 0` are true exactly when some row matches. The rule makes each of them `EXISTS` of the same subquery, with `SELECT 1` in place of the count. `count = 0`, `count <= 0`, and `count < 1` are true exactly when no row matches, so the rule makes each of them `NOT EXISTS`. The count can be on either side, as in `0 < (SELECT count(*) ...)`.

QUAACK replaces each constant with a placeholder before any rule runs. Thus the rule can't read the `0` or the `1`. It asks the literal oracle whether the placeholder holds the value the operator needs, and the oracle answers yes or no. The rewrite drops the placeholder. The literal sets keep such a placeholder at its slow literal in every set, since they only pick values for a placeholder that is compared with a table column. Thus every set runs the rewrite with the value the oracle saw.

`count(t.col)` counts only the rows where `t.col` isn't NULL. The rule makes it `EXISTS` too, and adds `t.col IS NOT NULL` to the subquery's `WHERE`. The column must be a column of a table in the subquery's own `FROM`: `t.col`, or a bare column that exactly one of those tables has, when every item of that `FROM` is a table. A column of an outer query would make the count that query's aggregate.

The comparison can be in any location: the `WHERE`, the select list, a `CASE`, a `HAVING`, under an `OR` or a `NOT`, in a subquery, in a CTE, or in a branch of a `UNION`. Neither side is ever NULL, so the comparison is only true or false, and so is `EXISTS`. The subquery can be correlated or not. The rule rewrites every count it can in one rewrite, nested ones too.

The rule does not change these:

- A subquery with `WITH`, `DISTINCT`, `GROUP BY`, `HAVING`, `WINDOW`, `ORDER BY`, `LIMIT`, or `OFFSET`, or a `UNION`. With `GROUP BY` or `OFFSET`, the subquery can give no row, and the count is NULL.
- A subquery whose select list is anything but one `count`, such as `max(...)`, `count(DISTINCT ...)`, `count(1)` (whose `1` is a placeholder), a count of an expression, or a `count` with `FILTER`, `ORDER BY`, or `OVER`. `count` must be `pg_catalog`'s, written bare or as `pg_catalog.count`.
- A comparison of the count with anything but a placeholder, such as a column or an expression, or a comparison of a cast of the count.
- An operator other than `=`, `<>`, `<`, `<=`, `>`, or `>=`, or one that names a schema other than `pg_catalog`.
- A test such as `count > 1` or `count >= 0`, whose constant isn't the one the operator needs.
- `ARRAY(SELECT count(*) ...)`, which is an array, not a count.
- A count of a column whose type is a composite type, or a domain over one. `IS NOT NULL` of a row is true only when every field isn't NULL, but `count` counts a row whose fields are all NULL.
- A count of `t.col` where `t`'s alias renames its columns, of a whole row (`count(t)` or `count(t.*)`), or of a function written as a column (`t.f`).
- A query that calls a volatile function anywhere. `EXISTS` stops at the first match, so a volatile call would run another number of times.
- A count whose `FROM` or `WHERE` holds something that can fail on some rows, such as a cast like `(o.metadata->>'total')::numeric`, a function call, or arithmetic like `/`. The count only checks its conditions on the rows its plan reads. A correlated count runs once for each outer row and sees only the rows that match it, and any count may read only the rows an index finds. Postgres can run `EXISTS` or `NOT EXISTS` as a semi-join, an anti-join, or a seq scan that checks the conditions on rows the count never reads. Then a value that can't be cast, or a zero it divides by, on one of those rows makes the rewrite fail where the original doesn't.

## Why it can be faster.

To count, Postgres has to find every matching row, even though the first one already settles the question. If a user has 200 submissions, the count reads all 200 just to compare the total with 0. `EXISTS` asks only whether one exists, so Postgres stops at the first match. In a `WHERE`, Postgres can also run `EXISTS` as a semi-join, a join that keeps each outer row once if it has any match, using an index or a hash table, instead of running the subquery once for each outer row.

## What it rests on.

Nothing. A count is never NULL and never below 0 by definition, so the rule needs no fact from the catalog, and it states no assumptions.

## Example.

This query keeps the registered users that have at least one graded submission, by counting the graded submissions of each user. `EXISTS` gives the same rows and stops at the first one.

QUAACK replaces each constant with a placeholder, such as `$1`, before any rule runs. Thus the example shows the constants as placeholders. Here `$3` is `0`. The rule made this "after" on Postgres 18, from these tables:

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
SELECT users.*
FROM public.users
WHERE
  users.workflow_state = $1
  AND (
    SELECT count(*)
    FROM public.submissions
    WHERE
      submissions.user_id = users.id
      AND submissions.workflow_state = $2
  ) > $3
```

After:

```sql
SELECT users.*
FROM public.users
WHERE
  users.workflow_state = $1
  AND EXISTS (
    SELECT 1
    FROM public.submissions
    WHERE
      submissions.user_id = users.id
      AND submissions.workflow_state = $2
  )
```
