# transitive_predicate_copy.

The rule copies a filter on one side of a column equality in a WHERE or inner-join ON to the other side.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

For each column equality `a.x = b.y` in a top-level `AND` of a `WHERE` or of an inner join's `ON`, the rule copies a filter on `a.x` to `b.y`. Postgres already carries `a.x = c` across the join, but it does not carry these filters. The filters that the rule copies are:

- An `IN` list of constants.
- A `<`, `<=`, `>`, or `>=` comparison with a constant.
- A `BETWEEN` of two constants.

The rule does not copy `IS NOT NULL`.

The copy goes in the same place as its source: the `WHERE` or that `ON`. The copy reuses the placeholders of the source, so it adds no literal values. The rule does not add a copy when the same conjunct is already in the `WHERE` or in an inner join's `ON`. The literal oracle decides this. Copies chain along `a.x = b.y = c.z`.

The rule refuses these cases:

- A constant with a cast or a `COLLATE`.
- A filter that calls a function.
- An equality whose columns differ in base type, such as an enum against text, or two different enums.
- An equality whose columns differ in collation.

The rule ignores type modifiers, so `varchar(20)` against `varchar(255)` is permitted. The rule also accepts these cases:

- Two columns of the same enum type.
- A column with a nondeterministic collation.
- A type whose `=`, `<`, `<=`, `>`, and `>=` are not its default btree operators.

The rule never uses, or copies to, a column on the nullable side of an outer join.

## Why it can be faster.

If `a.x = b.y` and `a.x` is one of a few values, then `b.y` must be one of those values too. A person sees that right away, but Postgres doesn't draw that conclusion for lists or ranges. It does for a single `=`. Without the copy, Postgres may read far more rows of the second table than it needs and throw most of them away at the join. With the copy written out, it can use an index on `b.y` to fetch only the rows that can match, and it gets a better estimate of how many rows the join will produce.

## What it rests on.

No assumption. Its output returns the same rows as its input on any data the schema allows.

## Example.

An association filtered by the id of the parent. The join states `assignments.id = submissions.assignment_id`. Thus the `IN` list on `assignments.id` is also true for `submissions.assignment_id`. The rule copies the list there, where an index on `submissions.assignment_id` can use it.

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
