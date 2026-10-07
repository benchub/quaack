# union_outer_filter_removal.

A WHERE conjunct on a UNION subquery's columns is removed when every arm's WHERE already applies it to the column it outputs.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

A top-level `WHERE` conjunct that reads only one `UNION` or `UNION ALL` subquery's output columns, qualified by its alias, is dropped when every arm's top-level `WHERE` holds the same conjunct on the columns that arm outputs in those positions. The literal oracle decides whether two placeholders match; no value is read. Every row an arm outputs passed its `WHERE`, `GROUP BY`, `DISTINCT ON`, `ORDER BY`, and `LIMIT` only pick among those rows, and `UNION` keeps one of each set of equal rows, so the outer conjunct already holds on every row. An arm column must be a qualified column of a table in the catalog, or a `*` it can expand from the catalog, and each position's columns must match in type and collation, so `UNION` casts nothing. It runs after `cte_hoist_dedupe`, so a conjunct's subquery reads the one shared top-level CTE. A conjunct with a subquery matches only if Postgres can analyze it under the top-level `WITH` alone, and no arm's nearer `WITH` hides a CTE it reads. It refuses a conjunct that calls a volatile function, a `LATERAL` or column-aliased `UNION` subquery or arm table, a `UNION` on an outer join's nullable side, an `INTERSECT` or `EXCEPT` anywhere in it, an arm with grouping sets, and an arm column read from a CTE or subquery. Only that conjunct goes, so the outer `GROUP BY` and `HAVING` stay as they were.

## What it rests on.

No assumption. Its output returns the same rows as its input on any data the schema allows.

## Example.

A filter on a `UNION` subquery's column that every arm already applies. The three placeholders hold the same literal, so the outer filter goes.

QUAACK replaces each constant with a placeholder, such as `$1`, before any rule runs, so the example shows them that way. The rule made this "after" on Postgres 18, from these tables:

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
SELECT work.*
FROM
  (
    SELECT submissions.id, submissions.user_id
    FROM public.submissions
    WHERE submissions.user_id = $1
    UNION
    SELECT enrollments.id, enrollments.user_id
    FROM public.enrollments
    WHERE enrollments.user_id = $2
  ) work
WHERE work.user_id = $3
```

After:

```sql
SELECT work.*
FROM
  (
    SELECT submissions.id, submissions.user_id
    FROM public.submissions
    WHERE submissions.user_id = $1
    UNION
    SELECT enrollments.id, enrollments.user_id
    FROM public.enrollments
    WHERE enrollments.user_id = $2
  ) work
```
