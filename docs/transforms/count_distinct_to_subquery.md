# count_distinct_to_subquery.

The rule turns a `count(DISTINCT e)` into a `count(e)` over a `SELECT DISTINCT` of the query's `GROUP BY` columns and `e`.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

A dashboard often counts distinct values in each group, such as the distinct users who did something in each course. The rule moves the query's `FROM` and `WHERE` into a subquery that keeps one row for each distinct pair of group and value. The outer query then counts those rows' values, grouped as before. So `SELECT t.g, count(DISTINCT e) FROM t WHERE p GROUP BY t.g` becomes `SELECT d.g, count(d.v) FROM (SELECT DISTINCT t.g, e AS v FROM t WHERE p) d GROUP BY d.g`.

The rule gives the subquery and its counted column fresh names, so they can't clash with any name the query uses. Each output keeps its name. With no `GROUP BY`, the outer query has none either, and it still gives one row of 0 when no row matches.

The rule takes a `SELECT` with a `FROM` whose select list holds:

- the grouping columns, each written `name.column`, and
- exactly one `count(DISTINCT e)`, or `pg_catalog.count(DISTINCT e)`, of one argument, with no `FILTER` and no `ORDER BY` of its own.

The `GROUP BY` must name exactly those columns, in any order. An `ORDER BY` may name a grouping column, an output's name, or an ordinal. The rule points a grouping column at the subquery's copy and leaves the rest alone. A `LIMIT`, an `OFFSET`, and a `WITH` stay on the outer query.

The rule refuses:

- a `HAVING`, a window function, a `WINDOW` clause, a `DISTINCT` on the query itself, or a set operation,
- any other item in the select list, such as a second aggregate,
- an `ORDER BY` item of any other kind, such as an expression,
- two grouping columns with the same column name, or two outputs with the same name,
- a counted value that is only a constant or a placeholder, whose type the subquery could read differently, and
- a query that might call a volatile function.

These cases are unsupported in v1:

- a grouping column written as a bare column, or an expression, in the select list or the `GROUP BY`,
- a `GROUP BY` that names a column the select list doesn't, or that uses an ordinal,
- more than one `count(DISTINCT)`, and
- a `count(DISTINCT)` in a subquery. The rule only rewrites the top-level query.

## Why it can be faster.

Postgres runs `count(DISTINCT e)` inside the aggregate. It sorts each group's values and counts the distinct ones, and it can't hash them. When the values don't fit in `work_mem`, that sort spills to temporary files on disk. A `SELECT DISTINCT` can use a hash aggregate instead, which holds one entry for each distinct pair. When there are many repeated pairs, as in an events table with many events for each user, the hash stays small, and the outer count reads far fewer rows. Postgres still picks a sort when that is cheaper, so it only gains plans to choose from.

## What it rests on.

The rule makes no assumption. Its output returns the same rows as its input, on any data that the schema allows. The subquery keeps one row for each distinct pair of group and value, so every group still has at least one row. Counting the values of those rows counts the group's distinct values. Both forms compare `e` with its type's equality and its collation, and both skip a `NULL` `e`. So a group whose values are all `NULL` still counts 0.

## Example.

This query counts the distinct students in each course, as Rails writes `Enrollment.where(workflow_state: "active").group(:course_id).distinct.count(:user_id)`, with an alias for the count.

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
SELECT enrollments.course_id, count(DISTINCT enrollments.user_id) AS students
FROM public.enrollments
WHERE enrollments.workflow_state = $1
GROUP BY enrollments.course_id
```

After:

```sql
SELECT d_1.course_id, count(d_1.user_id_1) AS students
FROM
  (
    SELECT
      DISTINCT
      enrollments.course_id, enrollments.user_id AS user_id_1
    FROM public.enrollments
    WHERE enrollments.workflow_state = $1
  ) d_1
GROUP BY d_1.course_id
```
