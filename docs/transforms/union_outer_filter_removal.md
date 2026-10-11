# union_outer_filter_removal.

The rule removes a WHERE conjunct on the columns of a UNION subquery. It does this when the WHERE of every arm already applies the conjunct to the column that the arm outputs.

It is one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule drops a top-level `WHERE` conjunct when these conditions are true:

- The conjunct reads only the output columns of one `UNION` or `UNION ALL` subquery, qualified by the alias of that subquery.
- The top-level `WHERE` of every arm holds the same conjunct, on the columns that the arm outputs in those positions.

The literal oracle decides whether two placeholders match. The rule reads no value.

Every row that an arm outputs passed the `WHERE` of that arm. `GROUP BY`, `DISTINCT ON`, `ORDER BY`, and `LIMIT` only select among those rows. `UNION` keeps one row from each set of equal rows. Thus the outer conjunct already holds on every row.

Each arm column must be a qualified column of a table in the catalog, or a `*` that the rule can expand from the catalog. The columns in each position must match in type and collation, so that `UNION` casts nothing.

The rule runs after `cte_hoist_dedupe`, so a subquery in a conjunct reads the one shared top-level CTE. A conjunct with a subquery matches only if both of these conditions are true:

- Postgres can analyze the conjunct with only the top-level `WITH`.
- No nearer `WITH` of an arm hides a CTE that the conjunct reads.

The rule refuses:

- a conjunct that calls a volatile function,
- a `LATERAL` or column-aliased `UNION` subquery or arm table,
- a `UNION` on the nullable side of an outer join,
- an `INTERSECT` or `EXCEPT` anywhere in the `UNION` subquery,
- an arm with grouping sets, and
- an arm column read from a CTE or subquery.

The rule removes only that conjunct. Thus the outer `GROUP BY` and `HAVING` do not change.

## What it rests on.

The rule makes no assumption. Its output returns the same rows as its input, on any data that the schema allows.

## Example.

This example has a filter on a column of a `UNION` subquery, and every arm already applies that filter. The three placeholders hold the same literal, so the rule removes the outer filter.

QUAACK replaces each constant with a placeholder, such as `$1`, before any rule runs. Thus the example shows the constants as placeholders. The rule made this "after" on Postgres 18, from these tables:

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
