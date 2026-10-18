# key_in_self_join.

The rule changes an IN subquery that reads the outer table again by a unique, not-null key. The result is the predicates of that table, and an EXISTS on what remains of the subquery.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule applies to `t.k IN (SELECT t2.k FROM t t2 ... WHERE P)`, where the subquery reads the outer table again by a key. The rule removes the inner `t2`, and moves its predicates to the outer `t`. It keeps an `EXISTS` on what remains of the subquery, correlated on `t.k`. If nothing remains, only the predicates remain. The rule handles each arm of a `UNION ALL` in the subquery separately, and joins the arms with `OR`.

`t.k = ANY (SELECT ...)` is the same test as `IN`, so the rule takes it too. It takes an `IN` anywhere in the statement where it's one of the conditions ANDed together in a `WHERE` or a join's `ON`: in the top query, a `UNION` arm, a subquery, a derived table, or a CTE. There, as in any `WHERE` or `ON`, a row the `IN` makes `NULL` is dropped as one it makes false is. The outer table must be one that `WHERE` or `ON` can name: in that SELECT's `FROM`, or on either side of that join. It must not be on the nullable side of an outer join among them, where it could be a `NULL` row that `IN` never matches but a moved predicate such as `t.x IS NULL` would. A `LEFT JOIN`'s right table is fine in that join's own `ON`, which sees the table's rows before the join fills it with `NULL`s.

A column needn't be written `name.column`. The rule reads a bare column as Postgres does, as the column of the one table that has it, by the catalog, and writes it qualified when it moves it. It refuses a bare column that none of the subquery's tables has, which would read the outer query, or that two have, and a bare tested column when the `FROM` it could name holds anything but plain tables whose columns the catalog knows.

The rule gives one rewrite for each `IN` it can rewrite. With two or more, it first gives one rewrite of all of them, so a query with more `IN`s than the generator chains rules deep still gets its fully rewritten form.

The rule refuses an `IN` under `OR` or `NOT`, in a select list, or in a `HAVING`, and an `IN` that tests a table of an enclosing query.

## Why it can be faster.

The subquery reads the same table the outer query already reads, only to filter it and hand back its key. Postgres then has to scan that table twice and match the two copies up. Because the key is unique, each outer row matches at most one inner row, and that row is the outer row itself. So the inner copy's filters can move straight onto the outer table, and the second scan goes away. Whatever the subquery checked in other tables stays as an `EXISTS`, which Postgres can stop at the first match.

## What it rests on.

The rule needs `k` to be unique and not null. The rule applies only when it can prove this. It states the catalog facts that it relies on as assumptions. assumption-check checks these assumptions again, as it checks all other assumptions.

Here, the rule states: `public.users (id)` is unique; `public.users.id` is not null.

## Example.

This example has an `IN` subquery that reads `users` again by its primary key. The rule moves the subquery's filter on `users` to the outer `users`. It keeps an `EXISTS` on `enrollments`.

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
SELECT users.*
FROM public.users
WHERE
  users.id IN (
    SELECT u2.id
    FROM
      public.users u2
      JOIN public.enrollments ON enrollments.user_id = u2.id
    WHERE
      u2.workflow_state = $1
      AND enrollments.course_id = $2
  )
```

After:

```sql
SELECT users.*
FROM public.users
WHERE
  users.workflow_state = $1
  AND EXISTS (
    SELECT 1
    FROM public.enrollments enrollments_1
    WHERE
      enrollments_1.course_id = $2
      AND enrollments_1.user_id = users.id
  )
```
