# transitive_predicate_copy.

A filter on one side of a column equality in a WHERE or inner-join ON is copied to the other side.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

For each column equality `a.x = b.y` in a top-level `AND` of a `WHERE` or an inner join's `ON`, a filter on `a.x` is copied to `b.y`. Postgres already carries `a.x = c` across the join, but not these. The filters copied are an `IN` list of constants, a `<`, `<=`, `>`, or `>=` comparison with a constant, and a `BETWEEN` of two constants. `IS NOT NULL` isn't copied. The copy goes in the same place as its source, the `WHERE` or that `ON`, and reuses the source's placeholders, so it adds no literal values. A copy isn't added when the same conjunct is already in the `WHERE` or an inner join's `ON`, which the literal oracle decides. Copies chain along `a.x = b.y = c.z`. It refuses a constant with a cast or a `COLLATE`, and a filter that calls a function. It refuses an equality whose columns differ in base type, such as an enum against text or two different enums, or in collation. It ignores type modifiers, so `varchar(20)` against `varchar(255)` is fine, and it accepts two columns of the same enum type, a column with a nondeterministic collation, and a type whose `=`, `<`, `<=`, `>`, and `>=` aren't its default btree operators. It never uses or copies to a column on an outer join's nullable side.

## What it rests on.

No assumption. Its output returns the same rows as its input on any data the schema allows.

## Example.

An association filtered by the parent's id. The join says `assignments.id = submissions.assignment_id`, so the `IN` list on `assignments.id` holds for `submissions.assignment_id` too, and the rule copies it there, where an index on `submissions.assignment_id` can use it.

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
SELECT submissions.*
FROM
  public.submissions
  JOIN public.assignments ON assignments.id = submissions.assignment_id
WHERE assignments.id IN ($1, $2, $3)
```

After:

```sql
SELECT submissions.*
FROM
  public.submissions
  JOIN public.assignments ON assignments.id = submissions.assignment_id
WHERE
  assignments.id IN ($1, $2, $3)
  AND submissions.assignment_id IN ($1, $2, $3)
```
