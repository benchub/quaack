# distinct_join_to_exists.

A SELECT DISTINCT of one table's columns over a join, with a unique, not-null key of that table among them, becomes that table alone with an EXISTS on the other tables, and no DISTINCT.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

`SELECT DISTINCT` of one table's columns over a join becomes that table with `EXISTS` on the others, and no `DISTINCT`. The select list and `ORDER BY` read only that table: its columns, its `*`, or expressions of them such as a `COLLATE`, a cast, or a function call, written `t.col` or as a bare column only that table has. No call may be volatile, set-returning, an aggregate, or a window function. The joins are all inner, and the other tables go in one `EXISTS` with every condition that reads them. A condition may hold a subquery, such as `t.id IN (SELECT ...)` or `NOT EXISTS (...)`, if it reads only the kept table. It stays in the `WHERE` unchanged. The subquery's `FROM` must be schema-qualified tables, with no `ONLY`, no alias that renames columns, and no join, and the subquery has no `WITH` or `UNION`. A column it reads from outside itself must be the kept table's, since the other tables are gone. It can't read the kept table's whole row, as `a.*`, either. The rule doesn't fire on a subquery in the select list, `ORDER BY`, `LIMIT`, or `OFFSET`. `ORDER BY`, `LIMIT`, and `OFFSET` carry over unchanged; with a `LIMIT` or `OFFSET`, the `ORDER BY` must hold every column of the key as `t.col`, so the order is total.

## What it rests on.

The select list holds every column of a unique key of the kept table, each column not null. The key may be of several columns. The rule fires only when it can prove this, and it states the catalog facts it relies on as assumptions, which assumption-check checks again like anyone else's.

Here it states: `public.users (id)` is unique; `public.users.id` is not null. For a key of several columns, it states each one not null.

## Example.

`SELECT DISTINCT` over a join, used only to filter `users`. The select list holds `users.id`, the primary key, so `EXISTS` gives the same rows with no `DISTINCT`.

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
SELECT
  DISTINCT
  users.*
FROM
  public.users
  JOIN public.enrollments ON enrollments.user_id = users.id
WHERE enrollments.course_id = $1
```

After:

```sql
SELECT users.*
FROM public.users
WHERE
  EXISTS (
    SELECT 1
    FROM public.enrollments
    WHERE
      enrollments.user_id = users.id
      AND enrollments.course_id = $1
  )
```
