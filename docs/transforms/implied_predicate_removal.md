# implied_predicate_removal.

The rule removes redundant predicates in a WHERE or an inner-join ON when an equality on the same column proves them.

This rule is one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule examines each `SELECT` separately: the top level, and each subquery, CTE, and set-operation arm. In each `SELECT`, the rule looks at the top-level `AND` of the `WHERE`, or of the `ON` of an inner join. There, a conjunct `col = c` drops another such conjunct on the same column that it proves. The rule can drop these conjuncts:

- `col <> d`
- `col IN (...)`
- `col NOT IN (...)`
- ranges
- `BETWEEN`
- duplicate conjuncts

An equality proves only conjuncts in its own `SELECT`. Its column must belong to one of that `SELECT`'s own tables. If a duplicate is in both the `ON` of an inner join and the `WHERE`, the rule drops it from the `WHERE`. If an `ON` becomes empty, the join becomes a cross join. The rule never moves an outer-join `ON` conjunct, and never uses one as proof.

The rule refuses these:

- A column with a nondeterministic collation.
- An equality whose constant is cast to a type other than the column's own type, modifiers included.
- A duplicate that can call a volatile function (`Catalog#calls_volatile?`).

Literals are compared only inside Postgres. Placeholders are bound as parameters, and cast to the type and collation of the column.

## What it rests on.

The rule needs no assumption. Its output returns the same rows as its input on any data that the schema allows.

## Example.

Rails often adds the conditions of a scope with `AND` to a query that already sets the column to one value. An example is `workflow_state = 'active'` beside `workflow_state NOT IN ('deleted', 'rejected')`. The equality proves the `NOT IN`, so the rule drops it.

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
