# not_in_to_not_exists.

A NOT IN subquery whose tested columns and selected columns are all not null becomes a NOT EXISTS correlated on each pair.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

`t.x NOT IN (SELECT s.y ...)`, a condition the `WHERE` ANDs, becomes `NOT EXISTS (... WHERE x = y)`, with the rest of the subquery as it was. A row works column by column: `(t.a, t.b) NOT IN (SELECT s.x, s.y ...)` becomes `NOT EXISTS (... WHERE a = x AND b = y)`. A subquery table under the name of an outer table the `NOT IN` tests gets a fresh alias. `<> ALL`, a row whose columns aren't all `name.column`, a subquery that selects a different number of columns, and a subquery that's a set operation or has `GROUP BY`, `LIMIT`, or the like are left alone.

## What it rests on.

`x` and `y` not null, and neither table on the nullable side of an outer join. For a row, that's every column on both sides: Postgres compares the rows pair by pair, so a NULL in one pair makes the comparison unknown when the other pairs match. `NOT IN` drops that row and `NOT EXISTS` keeps it. The rule fires only when it can prove this, and it states the catalog facts it relies on as assumptions, which assumption-check checks again like anyone else's.

Here it states: `public.users.id` is not null; `public.enrollments.user_id` is not null. For a row, it states each tested column and the column selected in its place, pair by pair.

## Example.

A `NOT IN` subquery on two not-null columns. Postgres runs `NOT EXISTS` as an anti-join, which it can't do for `NOT IN`.

QUAACK replaces each constant with a placeholder, such as `$1`, before any rule runs, so the example shows them that way. It also shows both queries as QUAACK deparses them, so the Rails form `users.id NOT IN (...)` reads `NOT users.id IN (...)`. The rule made this "after" on Postgres 18, from these tables:

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
SELECT users.*
FROM public.users
WHERE
  NOT users.id IN (
    SELECT enrollments.user_id
    FROM public.enrollments
    WHERE enrollments.course_id = $1
  )
```

After:

```sql
SELECT users.*
FROM public.users
WHERE
  NOT EXISTS (
    SELECT 1
    FROM public.enrollments
    WHERE
      enrollments.course_id = $1
      AND users.id = enrollments.user_id
  )
```
