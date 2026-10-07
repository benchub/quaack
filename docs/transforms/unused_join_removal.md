# unused_join_removal.

An inner join to a table the query reads nowhere else, on a validated foreign key whose columns are all not null, is removed.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

An inner join to a table that's read nowhere else is removed, in any `SELECT` at any depth. The join is an inner `JOIN` with no alias, `NATURAL`, or `USING`, one side of which is the joined table, or the joined table is an item of a comma-separated `FROM` whose `WHERE` ANDs the join's equalities at the top. Every condition of that `ON`, or every such conjunct, is a plain `=` between two columns written `name.column`, one of the joined table and the other of one joining table, which no outer join on its side can fill with `NULL`. They go with the table, and an empty `WHERE` goes too. Postgres removes an unused left join to a unique key, but never an inner one, since an inner join can drop rows; with the foreign key it can't. The foreign key pairs exactly the joining columns with the joined columns. It's validated, not deferrable, and its triggers are enabled. Both tables are plain tables, with no inheritance parent or child, so no partition or partitioned table, and the joined one has no row-level security, which the join would filter by. Each pair of columns has one type whose `=` is the key's own operator, and no nondeterministic collation. The table must be read nowhere else: no column reference that might resolve to it names it, other than in the conditions that go, and no bare column inside the `SELECT` that joins it has the name of one of its columns. Only references inside that `SELECT` might resolve to it, and not a `name.column` or `name.*` in the select list, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `WINDOW`, or `DISTINCT ON` of a nested `SELECT` whose own `FROM` binds the name first, so another `UNION` branch or a subquery such as Rails' `IN (SELECT users.id FROM users ...)` can reuse it. A join with an alias hides the names inside it. The `SELECT` that joins it has no bare `*`. Any other condition on it blocks the rule. It also refuses a query with a locking clause, or with a `NATURAL` or `USING` join anywhere. Unsupported in v1: a nullable joining column that the `WHERE` requires to be non-null, a joined table read with `ONLY`, and a `JOIN` whose `ON` holds a condition that doesn't read the joined table.

## What it rests on.

A foreign key from the joining columns to the joined columns, and each joining column not null. The rule fires only when it can prove this, and it states the catalog facts it relies on as assumptions, which assumption-check checks again like anyone else's.

Here it states: `public.submissions (assignment_id)` references `public.assignments (id)`; `public.submissions.assignment_id` is not null.

## Example.

A join, such as a scope can leave behind, to a table the query never reads. The foreign key on the not-null `submissions.assignment_id` says every submission has exactly one assignment, so the join neither drops nor repeats a row.

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
WHERE submissions.user_id = $1
```

After:

```sql
SELECT submissions.*
FROM public.submissions
WHERE submissions.user_id = $1
```
