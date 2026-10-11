# cte_hoist_dedupe.

CTEs with the same body, at any depth, become one CTE in the top-level WITH that every reference reads.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule merges CTEs at any depth when all of these match:

- Their bodies.
- Their column names.
- Their materialization option.

The merged CTE goes at the front of the top-level `WITH`, and every reference to a copy reads it. The literal oracle decides whether two placeholders match. No value is read. The copies leave their `WITH`s, and the rule removes each `WITH` that becomes empty.

The merged CTE keeps the name of the first copy, unless another CTE or an unrelated table reference uses that name. In that case, the name is `quaack_cte_<n>`, the first such name that the query does not use. Each renamed reference keeps its old name as an alias. Thus a nearer CTE of the same name can never hide the merged CTE.

A merged plain CTE can now be materialized, because the query reads it more than once. plan-pruning and the steps after it decide whether that helps.

A copy merges only if Postgres can analyze its body alone. Thus the copy:

- Is not correlated.
- Writes no bare name that is also the name of a FROM item in it, such as `name` in `FROM ... name WHERE name IS NULL`. Where the copy is, that name reads a column of that name in an outer query. In the body alone, it reads the whole row of the item, and the body still prepares.
- Reads no CTE from outside its body.
- Calls no volatile function.

The rule refuses a copy in a `RECURSIVE` `WITH`. It refuses the whole query when the top-level `WITH` is `RECURSIVE`, or when any CTE modifies data. A copy inside the body of another copy moves with that copy.

## What it rests on.

No assumption. Its output returns the same rows as its input on any data the schema allows.

## Example.

Two subqueries, each with its own copy of the same CTE. The rule keeps one copy, at the top, and both subqueries read it. The two placeholders hold the same literal, so the copy keeps the placeholder of the first copy.

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
