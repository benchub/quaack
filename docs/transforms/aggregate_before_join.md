# aggregate_before_join.

The rule aggregates a joined table's rows by its join columns before the join, when the query groups by a key of the other table.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

Rails counts a has-many association for each row with `joins(:orders).group("users.id").count`. The query joins the two tables and groups the joined rows by the first table's key. The rule moves the joined table into a derived table that groups it by the columns the join compares. The outer query joins that derived table in its place and has no `GROUP BY`. So `SELECT t.k, count(*) FROM t JOIN s ON s.f = t.k WHERE p(s) AND q(t) GROUP BY t.k` becomes `SELECT t.k, d.a FROM t JOIN (SELECT s.f, count(*) AS a FROM s WHERE p(s) GROUP BY s.f) d ON d.f = t.k WHERE q(t)`.

The rule gives the derived table and its aggregate columns fresh names, so they can't clash with any name the query uses. Each output keeps its name. A condition that reads only the joined table moves into the derived table, and so does a `HAVING`. A condition that reads only the grouped table stays in the outer `WHERE`. An `ORDER BY`, a `LIMIT`, and an `OFFSET` stay on the outer query.

The rule takes a `SELECT` that meets all of these:

- Its `FROM` is exactly two plain tables, in an inner join or a comma join.
- Each condition its `ON` and `WHERE` hold, joined by `AND`, is either an equality between a column of each table or a test of only one table. At least one is an equality. Each equality compares two columns of one type, whose `=` is the type's default, with no nondeterministic collation.
- Its `GROUP BY` names only columns of one table, and those columns hold a unique, not-null key of it.
- Its select list holds columns of that table and aggregate calls that read only the other table.
- Every column is written `name.column`.

An `ORDER BY` may name an ordinal, an output's name, or an expression of the grouped table's columns.

The rule refuses:

- an outer join, a third table, or a join with `USING` or `NATURAL`,
- a `DISTINCT` on the query itself, a window function, a `WITH`, or a set operation,
- a `*` in the select list,
- an aggregate that reads the grouped table, or any other item in the select list,
- a condition that reads both tables and isn't a plain equality, such as an `OR`,
- a `HAVING` that reads the grouped table,
- an `ORDER BY` of an aggregate,
- a condition or an aggregate argument that moves into the derived table and can raise an error on some rows, such as a division or a cast, and
- a query that might call a volatile function.

These cases are unsupported in v1:

- a subquery anywhere in the query,
- a column written without its table's name, and
- a `GROUP BY` of grouping sets, which QUAACK refuses before any rule runs.

## Why it can be faster.

Postgres runs the join first. Each order row comes out of the join with the user columns that the query needs, and the aggregate then groups all of those rows. When there are many orders for each user, the join's output is large, and the aggregate's hash table holds the wider user columns. If it doesn't fit in `work_mem`, it spills to temporary files on disk. Aggregating first groups only the order table's join column and aggregates. That hash table is smaller, and the join then matches one row for each user instead of every order. Postgres doesn't move an aggregate below a join on its own, so it can't find this plan without the rewrite.

## What it rests on.

The rule rests on the grouped table's key being unique and each of its columns being not null. So each group of the original is one row of the grouped table. Every aggregate reads only the other table, so a group's aggregates read just the rows of the other table that join that row. Those rows are one group of the derived table, since the grouping and the join's `=` agree on which values are equal. So each row of the grouped table joins at most one row of the derived table, and that row holds its aggregates. A row with nothing to join is dropped by both forms.

The derived table also reads rows of the other table that join no row of the grouped table, which the original never reads. The rule refuses a moved condition or aggregate argument that can raise on some rows. It takes the same `LIKE` risk as `or_to_union`, with a parameter pattern that ends in a lone backslash. An aggregate's own overflow, such as a `float8` sum's, can still raise in a group that the join then drops. v1 accepts that.

## Example.

This query counts each student's graded submissions, as Rails writes `User.joins(:submissions).where(submissions: { workflow_state: "graded" }).group("users.id").count`.

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
SELECT count(*) AS count_all, users.id AS users_id
FROM public.users
INNER JOIN public.submissions ON submissions.user_id = users.id
WHERE submissions.workflow_state = $1
GROUP BY users.id
```

After:

```sql
SELECT quaack_pre_1.a_1 AS count_all, users.id AS users_id
FROM public.users
JOIN
  (
    SELECT submissions.user_id, count(*) AS a_1
    FROM public.submissions
    WHERE submissions.workflow_state = $1
    GROUP BY submissions.user_id
  ) quaack_pre_1
  ON quaack_pre_1.user_id = users.id
```
