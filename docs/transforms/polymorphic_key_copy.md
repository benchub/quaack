# polymorphic_key_copy.

A filter can limit a joined parent to one Rails polymorphic type and id. Then the rule filters the child's own column for that type to the same id.

It is one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

This is a heuristic rule. It looks for `child.j = parent.id` and the filters `parent.<p>_type = $m AND parent.<p>_id = $n`, in a top-level `AND` of the `WHERE` or of an inner join's `ON`. Then it adds `child.<x>_id = $n` to the `WHERE`, so that the query can use an index on the child's copy. These conditions must be true:

- Each column is qualified.
- Each constant is a bare placeholder.
- Both tables are plain tables.
- Neither table is on the nullable side of an outer join.

The constant stays a placeholder, and the copy reuses it.

`<x>_id` is a column of the child, and the type literal is the class name for `<x>`. The class name is `<x>` in CamelCase, with at most four words. Each `_` between words reads either as nothing or as `::`. Thus `course_id` is `Course`, and `foo_bar_id` is `FooBar` or `Foo::Bar`. The literal oracle decides which class name the type literal is. No value is read.

If the column has foreign keys, each foreign key must reference `<x>s` or `<x>es`. The rule refuses when two columns of the child match. It adds nothing when the copy is already there. The rule does not support single-table inheritance or acronym inflections.

## What it rests on.

It is a heuristic rule. It rests on a `denormalized_equal` assumption, which the schema cannot state. The assumption is that the child's copy equals the parent's polymorphic id wherever the parent's type column names that class. assumption-check checks the assumption against the data before the rewrite continues. Thus the rewrite is only as good as the data was at that time. The report says so, and names the columns.

Here, the rule states: `public.submissions.course_id` equals `public.assignments.context_id` wherever `public.assignments.context_type` is `'Course'`.

## Example.

A Rails polymorphic association, `assignments.context_type` and `assignments.context_id`, copied into `submissions.course_id`. When a filter limits the parent to one course, the rule also filters the child's own copy of the course id. Thus the query can use an index on `submissions.course_id`.

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
