# not_in_to_not_exists.

The rule changes a NOT IN subquery into a NOT EXISTS that is correlated on each pair of columns. It does this only when all the tested columns and all the selected columns are not null.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule operates on `t.x NOT IN (SELECT s.y ...)`. The rule changes it to `NOT EXISTS (... WHERE x = y)`. The remainder of the subquery does not change.

The rule handles a row column by column: `(t.a, t.b) NOT IN (SELECT s.x, s.y ...)` becomes `NOT EXISTS (... WHERE a = x AND b = y)`.

The subquery can also be a `UNION` or `UNION ALL` of such SELECTs, nested in any way. The rule changes it to one `NOT EXISTS` for each branch, joined with AND, in the location of the `NOT IN`. For example, `t.x NOT IN (SELECT s.y ... UNION SELECT r.z ...)` becomes `NOT EXISTS (... WHERE x = y) AND NOT EXISTS (... WHERE x = z)`.

If a table in the subquery has the same name as an outer table that the `NOT IN` tests, the rule gives the subquery table a fresh alias.

The `NOT IN` can be at any location in a SELECT of the statement: the `WHERE`, the `HAVING`, the select list, a `CASE`, the `ON` of a join, under an `OR` or a `NOT`, in a subquery, in a `FROM` subquery, in a `WITH`, or in a branch of a `UNION`. It belongs to the nearest SELECT around it, and its columns must name the `FROM` of that SELECT. A `UNION` subquery becomes `NOT EXISTS` conditions joined with AND, in the location of the `NOT IN`.

`x <> ALL (SELECT y ...)` of one column means the same as `x NOT IN (SELECT y ...)`. The rule gives it the same rewrite when the `<>` that Postgres uses between the two columns is the negator of the `=` that it would use. The rule asks the catalog. Both operators must be operators of `pg_catalog` that take exactly the types of the columns, and the two columns must have the same collation. A column of a domain type has no operator of its own, so the rule refuses it.

The rule does not change these:

- A `<> ALL` of a row, any other `ALL` operator, and `ANY`.
- A `NOT IN` in a SELECT with `GROUP BY ROLLUP`, `CUBE`, or `GROUPING SETS`. These fill a grouped column with NULL in the rows that total it.
- A `NOT IN` that occurs again, identical, in the same SELECT, when a copy is in the `GROUP BY`, `DISTINCT ON`, or `ORDER BY`. Postgres needs those copies to match: the copy in the select list must match the copy in the `GROUP BY`, and `DISTINCT ON` must match the start of `ORDER BY`. Thus a rewrite of one copy would fail to plan. The rule gives one rewrite for each copy, and does not rewrite the copies together (20261010-12).
- A tested column that is not a column of a table in the `FROM` of the SELECT that holds the `NOT IN`, such as a column of an enclosing query.
- A row whose columns are not all `name.column`.
- A subquery, or a `UNION` branch, that selects a different number of columns.
- A subquery, or a `UNION` branch, that has `GROUP BY`, `LIMIT`, or a similar clause, or that is a `VALUES` list.
- A `UNION` with its own `WITH`, `ORDER BY`, or `LIMIT`.
- An `INTERSECT` or an `EXCEPT`, alone or at any location in a `UNION`. `x` is in an `INTERSECT` when it is in every branch, so the rewrite would need an OR of `NOT EXISTS`. The rows that an `EXCEPT` keeps depend on the contents of the other branch, not on `x`.
- A `UNION` whose branches select, in the same position, columns of different types or collations. A typmod does not count, so `varchar(10)` next to `varchar(20)` is permitted.
- A `UNION` without `ALL` of a type that Postgres cannot dedupe, such as `box`.
- A row with a pair whose `=` is not an operator of a btree family, such as the `=` of `box`.

## Why it can be faster.

`NOT IN` has awkward rules for `NULL`: if the subquery returns even one `NULL`, `NOT IN` can't say "not in" for anything. Postgres has to honor that, so it often runs `NOT IN` by checking each outer row against the whole subquery result, which gets slow as the result grows. `NOT EXISTS` doesn't have that quirk, so Postgres can run it as an anti-join: a join that keeps only the rows with no match, using an index or a hash table. When neither side can be `NULL`, the two forms mean the same thing, and the anti-join is usually much faster.

## What it rests on.

The rule rests on these conditions: `x` and `y` are not null, and neither table is on the nullable side of an outer join.

These conditions also make any location safe. `NOT IN` gives NULL, not false, for a NULL `x`, or for a NULL `y` in the subquery when `x` is not found. A `WHERE` drops NULL and false alike. But a select list, a `CASE`, or `IS NULL` shows the difference, and `NOT EXISTS` gives true. When every column is not null, the condition is only true or false, so `NOT EXISTS` gives the same value at any location. The exception is a grouping set, which makes a grouped column NULL in some rows. Thus the rule refuses a grouping set.

For a row, the conditions apply to every column on both sides. Postgres compares the rows pair by pair. Thus, when the other pairs match, a NULL in one pair makes the comparison unknown. `NOT IN` drops that row, but `NOT EXISTS` keeps it.

For a `UNION`, the conditions apply to the selected columns of every branch. `x` is in a `UNION` when it is in one of the branches. Thus, when there is no NULL at any location, the `NOT EXISTS` of each branch, joined with AND, agree with the `NOT IN`. One NULL in any branch causes `NOT IN` to give no rows.

The rule also does three checks itself, and it does not state them as assumptions:

- In a `UNION`, the column in the same position of every branch has the same type and collation. A `UNION` compares as the common type of its columns. Thus, with a `numeric` branch next to a `float8` branch, `NOT IN` compares as `float8` and `NOT EXISTS` compares as `numeric`. The rule compares the types without their typmods. A typmod does not change the `=` of a type. It also does not change the values on which a `UNION` dedupes, because Postgres stores each value already cut to the typmod of its column. Also, a `UNION` of `varchar(10)` and `varchar(20)` is of plain `varchar`. Thus `NOT IN` and `NOT EXISTS` compare such columns with the same `=`, and they give the same rows, with or without `ALL`.
- For a row, Postgres uses the `=` of each pair. Postgres refuses a row comparison unless the `=` of each pair is in a btree family. In that case, `NOT IN` is an error, but `NOT EXISTS` would give rows. The rule asks Postgres whether it accepts each pair.
- For a `UNION` without `ALL`, Postgres can dedupe the type of each column. Postgres refuses a type that it cannot dedupe, such as `box`, so `NOT IN` is also an error in that case. The rule asks Postgres whether it can dedupe the type.

The rule fires only when it can prove this. It states the catalog facts that it relies on as assumptions. Then assumption-check checks these assumptions again, as it does for any other assumptions.

Here, the rule states: `public.users.id` is not null; `public.enrollments.user_id` is not null. For a row, it states each tested column and the column selected in the same position, pair by pair. For a `UNION`, it states them for each branch, and it states each column one time.

## Example.

This example is a `NOT IN` subquery on two not-null columns. Postgres runs `NOT EXISTS` as an anti-join, but it cannot do this for `NOT IN`.

QUAACK replaces each constant with a placeholder, such as `$1`, before any rule runs. Thus the example shows the constants as placeholders. The example also shows both queries in the form that QUAACK deparses them to. Thus the Rails form `users.id NOT IN (...)` shows as `NOT users.id IN (...)`. The rule made this "after" on Postgres 18, from these tables:

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
