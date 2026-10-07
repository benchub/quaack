# or_to_union.

An OR whose arms read different tables or subqueries becomes a UNION of one query per arm, which the rest of the query reads in place of its tables.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

A top-level `OR` whose arms read different tables or subqueries becomes a `UNION` of one query per arm: the query's `FROM` and `WHERE` with only that arm in the `OR`'s place. Each arm selects the columns the rest of the query uses and a key of every `FROM` table. The query then reads the `UNION` in place of its tables, so its select list, aggregates, `DISTINCT`, `ORDER BY`, and `LIMIT` apply to the whole `UNION`. It leaves alone a query with `GROUP BY`, `HAVING`, a window function, `DISTINCT ON`, a locking clause, `WITH`, an outer join, or a `FROM` item that isn't a table, and one that uses a column of a type `UNION` can't compare, such as `json`.

## What it rests on.

A unique, not-null key of every `FROM` table, one column each, so `UNION` removes exactly the rows both arms return. The rule fires only when it can prove this, and it states the catalog facts it relies on as assumptions, which assumption-check checks again like anyone else's.

Here it states: `public.users (id)` is unique; `public.users.id` is not null.

## Example.

An `OR` of two `IN` subqueries on different tables. The rule makes one query per arm and reads their `UNION`. `users.id` is the primary key, so `UNION` drops only a user both arms return.

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
SELECT users.id, users.name
FROM public.users
WHERE
  users.id IN (
    SELECT enrollments.user_id
    FROM public.enrollments
    WHERE enrollments.course_id = $1
  ) OR users.id IN (
    SELECT submissions.user_id
    FROM public.submissions
    WHERE submissions.assignment_id = $2
  )
```

After:

```sql
SELECT arms_1.id_1 AS id, arms_1.name_1 AS name
FROM
  (
    SELECT users.id AS id_1, users.name AS name_1
    FROM public.users
    WHERE
      users.id IN (
        SELECT enrollments.user_id
        FROM public.enrollments
        WHERE enrollments.course_id = $1
      )
    UNION
    SELECT users.id AS id_1, users.name AS name_1
    FROM public.users
    WHERE
      users.id IN (
        SELECT submissions.user_id
        FROM public.submissions
        WHERE submissions.assignment_id = $2
      )
  ) arms_1
```
