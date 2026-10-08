# not_in_to_not_exists.

A NOT IN subquery whose tested columns and selected columns are all not null becomes a NOT EXISTS correlated on each pair.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

`t.x NOT IN (SELECT s.y ...)`, a condition the `WHERE` ANDs, becomes `NOT EXISTS (... WHERE x = y)`, with the rest of the subquery as it was. A row works column by column: `(t.a, t.b) NOT IN (SELECT s.x, s.y ...)` becomes `NOT EXISTS (... WHERE a = x AND b = y)`. A `UNION` or `UNION ALL` of such SELECTs, nested any way, becomes one `NOT EXISTS` per branch, ANDed in the `NOT IN`'s place: `t.x NOT IN (SELECT s.y ... UNION SELECT r.z ...)` becomes `NOT EXISTS (... WHERE x = y) AND NOT EXISTS (... WHERE x = z)`. A subquery table under the name of an outer table the `NOT IN` tests gets a fresh alias. These are left alone:

- `<> ALL`.
- A row whose columns aren't all `name.column`.
- A subquery, or a `UNION` branch, that selects a different number of columns.
- A subquery, or a `UNION` branch, that has `GROUP BY`, `LIMIT`, or the like, or is a `VALUES` list.
- A `UNION` with its own `WITH`, `ORDER BY`, or `LIMIT`.
- An `INTERSECT` or an `EXCEPT`, alone or anywhere in a `UNION`. `x` is in an `INTERSECT` when it's in every branch, which would take an OR of `NOT EXISTS`, and the rows an `EXCEPT` keeps hang on what the other branch holds, not on `x`.
- A `UNION` whose branches select, in one place, columns of different types or collations.
- A row with a pair whose `=` isn't an operator of a btree family, such as `box`'s.

## What it rests on.

`x` and `y` not null, and neither table on the nullable side of an outer join. For a row, that's every column on both sides: Postgres compares the rows pair by pair, so a NULL in one pair makes the comparison unknown when the other pairs match. `NOT IN` drops that row and `NOT EXISTS` keeps it. For a `UNION`, it's every branch's selected columns: `x` is in a `UNION` when it's in one of its branches, so with no NULL anywhere, the `NOT EXISTS` of each branch, ANDed, agree with the `NOT IN`. One NULL in any branch makes `NOT IN` give no rows at all.

The rule also checks two things itself, which it doesn't state as assumptions:

- In a `UNION`, every branch's column in one place has the same type and collation. A `UNION` compares as its columns' common type, so a `numeric` branch beside a `float8` one is compared as `float8` by `NOT IN` and as `numeric` by `NOT EXISTS`.
- For a row, Postgres takes each pair's `=`. It refuses a row comparison unless each pair's `=` is in a btree family, so `NOT IN` is an error where `NOT EXISTS` would give rows. The rule asks Postgres whether it takes each pair.

The rule fires only when it can prove this, and it states the catalog facts it relies on as assumptions, which assumption-check checks again like anyone else's.

Here it states: `public.users.id` is not null; `public.enrollments.user_id` is not null. For a row, it states each tested column and the column selected in its place, pair by pair. For a `UNION`, it states them for each branch, and each column once.

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
