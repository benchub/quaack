# implied_predicate_removal.

Redundant predicates in a WHERE or inner-join ON are removed when an equality on the same column proves them.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

Within each `SELECT` on its own (the top level, and each subquery, CTE, and set-operation arm), `col = c` in the top-level `AND` of its `WHERE` or an inner join's `ON` drops another such conjunct on the same column that it proves: `col <> d`, `col IN (...)`, `col NOT IN (...)`, ranges, `BETWEEN`, and duplicate conjuncts. An equality proves only what's in its own `SELECT`, and its column must belong to one of that `SELECT`'s own tables. A duplicate in both an inner join's `ON` and the `WHERE` is dropped from the `WHERE`, and an `ON` left empty makes a cross join. Outer-join `ON` conjuncts are never moved and never used as proof. It refuses a column with a nondeterministic collation, an equality whose constant is cast to any type but the column's own, modifiers included, and a duplicate that might call a volatile function (`Catalog#calls_volatile?`). Literal comparison stays inside Postgres, with placeholders bound as parameters and cast to the column type and collation.

## What it rests on.

No assumption. Its output returns the same rows as its input on any data the schema allows.

## Example.

Rails often ANDs a scope's own conditions onto a query that already pins the column, such as `workflow_state = 'active'` beside `workflow_state NOT IN ('deleted', 'rejected')`. The equality proves the `NOT IN`, so the rule drops it.

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
SELECT enrollments.*
FROM public.enrollments
WHERE
  enrollments.workflow_state = $1
  AND enrollments.workflow_state NOT IN ($2, $3)
  AND enrollments.course_id = $4
```

After:

```sql
SELECT enrollments.*
FROM public.enrollments
WHERE
  enrollments.workflow_state = $1
  AND enrollments.course_id = $4
```
