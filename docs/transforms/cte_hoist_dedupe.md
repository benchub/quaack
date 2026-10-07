# cte_hoist_dedupe.

CTEs with the same body, at any depth, become one CTE in the top-level WITH that every reference reads.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

CTEs at any depth whose bodies, column names, and materialization option all match become one CTE at the front of the top-level `WITH`, and every reference to a copy reads it. The literal oracle decides whether two placeholders match; no value is read. The copies leave their `WITH`s, and a `WITH` left empty goes. The merged CTE keeps the first copy's name unless another CTE or an unrelated table reference uses it; then it's `quaack_cte_<n>`, the first such name the query doesn't use, and each renamed reference keeps its old name as an alias. So a nearer CTE of the same name can never hide it. A merged plain CTE may now be materialized, since it's read more than once; plan-pruning onward decide whether that helps. A copy merges only if Postgres can analyze its body alone, so it isn't correlated, it reads no CTE from outside its body, and it calls no volatile function. It refuses a copy in a `RECURSIVE` `WITH`, and the whole query when the top-level `WITH` is `RECURSIVE` or any CTE modifies data. A copy inside another copy's body moves with it.

## What it rests on.

No assumption. Its output returns the same rows as its input on any data the schema allows.

## Example.

Two subqueries, each with its own copy of the same CTE. The rule keeps one copy, at the top, and both subqueries read it. The two placeholders hold the same literal, so the copy keeps the first one's.

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
SELECT enrollments.id
FROM public.enrollments
WHERE
  enrollments.course_id IN (
    WITH active_courses AS (
      SELECT courses.id
      FROM public.courses
      WHERE courses.workflow_state = $1
    )
    SELECT active_courses.id
    FROM active_courses
  ) OR enrollments.user_id IN (
    WITH active_courses AS (
      SELECT courses.id
      FROM public.courses
      WHERE courses.workflow_state = $2
    )
    SELECT active_courses.id
    FROM active_courses
  )
```

After:

```sql
WITH active_courses AS (
  SELECT courses.id
  FROM public.courses
  WHERE courses.workflow_state = $1
)
SELECT enrollments.id
FROM public.enrollments
WHERE
  enrollments.course_id IN (
    SELECT active_courses.id
    FROM active_courses
  ) OR enrollments.user_id IN (
    SELECT active_courses.id
    FROM active_courses
  )
```
