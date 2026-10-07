# polymorphic_key_copy.

Where a joined parent is filtered to one Rails polymorphic type and id, the child's own column for that type is filtered to the same id.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

A heuristic rule. With `child.j = parent.id` and the filters `parent.<p>_type = $m AND parent.<p>_id = $n`, in a top-level `AND` of the `WHERE` or an inner join's `ON`, it adds `child.<x>_id = $n` to the `WHERE`, so an index on the child's copy can be used. Each column is qualified, each constant a bare placeholder, and both tables plain tables, neither on an outer join's nullable side. The constant stays a placeholder and the copy reuses it. `<x>_id` is a column of the child whose class name the type literal is: `<x>` in CamelCase, of at most four words, with each `_` between words read either as nothing or as `::`, so `course_id` is `Course` and `foo_bar_id` is `FooBar` or `Foo::Bar`. The literal oracle decides which; no value is read. If the column has foreign keys, each must reference `<x>s` or `<x>es`. It refuses when two of the child's columns match, and it adds nothing when the copy is already there. Single-table inheritance and acronym inflections aren't supported.

## What it rests on.

It's a heuristic rule. It rests on a `denormalized_equal` assumption, which the schema can't state: the child's copy equals the parent's polymorphic id wherever the parent's type column names that class. assumption-check checks it against the data before the rewrite goes on, so the rewrite is only as good as the data was then, and the report says so, naming the columns.

Here it states: `public.submissions.course_id` equals `public.assignments.context_id` wherever `public.assignments.context_type` is `'Course'`.

## Example.

A Rails polymorphic association, `assignments.context_type` and `assignments.context_id`, copied into `submissions.course_id`. With the parent filtered to one course, the rule filters the child's own copy of the course id too, so an index on `submissions.course_id` can be used.

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
WHERE
  assignments.context_type = $1
  AND assignments.context_id = $2
```

After:

```sql
SELECT submissions.*
FROM
  public.submissions
  JOIN public.assignments ON assignments.id = submissions.assignment_id
WHERE
  assignments.context_type = $1
  AND assignments.context_id = $2
  AND submissions.course_id = $2
```
