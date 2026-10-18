# left_join_to_inner.

The rule turns a `LEFT JOIN` into an inner join when every row on its left side has exactly one match. The join must be on a validated foreign key, and all columns of that key must be not null.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule turns a `LEFT JOIN` into an inner join. It works in any `FROM` at any depth, such as in a subquery, a CTE, or a `UNION` arm. The right side of the `LEFT JOIN` must be one table, the joined table. The join may have an alias.

Every condition of the join's `ON` must be a plain `=` between two columns written `name.column`. One column is of the joined table. The other column is of one table on the join's left side, the joining table. No outer join on the left side can fill the joining table with `NULL`, because a row of `NULL`s matches no row of the joined table.

A `LEFT JOIN` keeps every row of its left side. When a row has no match, the join fills the joined table's columns with `NULL`. An inner join drops that row instead. With the foreign key, every row of the left side has exactly one match, so the two joins return the same rows. The rule needs all of these conditions:

- The foreign key pairs exactly the joining columns with the joined columns.
- The foreign key is validated and not deferrable, and its triggers are enabled.
- Both tables are plain tables, with no inheritance parent or child, so neither is a partition or a partitioned table.
- The joined table has no row-level security, because the join would filter by it.
- Each pair of columns has one type, whose `=` is the key's own operator, and no nondeterministic collation.
- Each joining column is not null.

The rule gives one rewrite for each `LEFT JOIN` that it can change, and each rewrite starts from the original query. A table that one `LEFT JOIN` brings in is on the nullable side of that join. So a second `LEFT JOIN` from that table changes only after the first one is inner, in the rules' second round.

The rule refuses:

- an `ON` with any other condition, on either side, because the `LEFT JOIN` keeps the rows that fail it,
- a `NATURAL` or `USING` join, which has no `ON`,
- a joined side that is a subquery or another join, and a joined table read with `ONLY` or with column aliases, and
- a locking clause, such as `FOR UPDATE`. QUAACK refuses these queries before any rule runs.

These cases are unsupported in v1:

- a `RIGHT JOIN`, even one with the joining table on its left,
- a `FULL JOIN`, which the same foreign key could make a `LEFT JOIN`,
- a joining table that is a subquery, a CTE, or a function, or that an aliased join on the left side hides, and
- a nullable joining column that the `WHERE` requires to be non-null.

## Why it can be faster.

A `LEFT JOIN` limits the plans Postgres can choose. It has to return every row of the left side, even one with no match, so it can't start from the joined table and stop early. So for `ORDER BY users.name LIMIT 20`, it joins every one of the course's enrollments to its user, sorts them all by name, and keeps 20. An inner join can be read in either order. Postgres can walk an index on `users.name` in order, look up each user's rows, and stop once it has 20. Postgres already makes a `LEFT JOIN` inner when the `WHERE` throws away the rows that it fills with `NULL`, but it doesn't use a foreign key to do so.

## What it rests on.

The rule needs a foreign key from the joining columns to the joined columns. Each joining column must also be not null. The rule fires only when it can prove this. It states the catalog facts that it relies on as assumptions. As with any other assumption, assumption-check checks them again.

Here it states: `public.enrollments (user_id)` references `public.users (id)`; `public.enrollments.user_id` is not null.

## Example.

This query lists a course's roster, sorted by name, as Rails writes `Enrollment.where(course_id: 42).eager_load(:user).order("users.name").limit(20)`, with a shorter select list. Rails' `eager_load` joins a `belongs_to` association with a `LEFT OUTER JOIN`. The foreign key on the not-null `enrollments.user_id` says that every enrollment has exactly one user. Thus the `LEFT JOIN` never fills a row with `NULL`, and an inner join returns the same rows.

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
SELECT enrollments.id, enrollments.type, users.id, users.name
FROM
  public.enrollments
  LEFT JOIN public.users ON users.id = enrollments.user_id
WHERE enrollments.course_id = $1
ORDER BY users.name
LIMIT $2
```

After:

```sql
SELECT enrollments.id, enrollments.type, users.id, users.name
FROM
  public.enrollments
  JOIN public.users ON users.id = enrollments.user_id
WHERE enrollments.course_id = $1
ORDER BY users.name
LIMIT $2
```
