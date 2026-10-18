# subquery_distinct_removal.

The rule removes a `DISTINCT`, an `ORDER BY`, or a `GROUP BY` of just the select list's columns from a subquery whose reader ignores duplicate rows and their order.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

Some readers of a subquery only ask which rows it returns. They don't count the copies of a row, and they don't look at the order. The rule knows these readers:

- The subquery of an `IN`, `= ANY`, `NOT IN`, or `<> ALL`. Each asks only whether some row of the subquery equals the tested value, or whether none does. The `=` or `<>` can also be written `OPERATOR(pg_catalog.=)` or `OPERATOR(pg_catalog.<>)`.
- An arm under a `UNION`, `INTERSECT`, or `EXCEPT` without `ALL`, at any depth. That set operation removes the duplicates of everything under it.
- An arm of a set operation that is one of these subqueries, as in `x IN (SELECT ... UNION ALL SELECT ...)`.

An arm can reach its reader through a `UNION ALL` or an `INTERSECT ALL`. Each of these gives the same set of rows, however many copies of a row its arms hold. An `EXCEPT ALL` in between cuts the arm off from its reader, because it subtracts counts: one more copy of a row on either side can add that row or remove it. So does a `UNION ALL` or `INTERSECT ALL` with its own `LIMIT` or `OFFSET`.

The rule leaves `EXISTS` alone, because Postgres already drops these clauses from an `EXISTS` subquery. A scalar subquery, an `ARRAY(...)`, a subquery in `FROM`, a CTE, and the top-level query all see every row, so the rule leaves them alone too.

From each subquery that such a reader reads, the rule removes these clauses:

- A plain `DISTINCT`. It doesn't remove `DISTINCT ON`, which picks one row of each group by the `ORDER BY`.
- A `GROUP BY` whose items are exactly the select list's columns, in any order, each written the same way in both. The `GROUP BY` must have no `HAVING`. With no aggregate in the select list, such a `GROUP BY` works as a `DISTINCT`.
- An `ORDER BY`.

`DISTINCT` and `GROUP BY` merge values that their type calls equal. A reader that compares the values in another way could tell the merged copies apart. For example, `text = citext` compares as `text`, so it tells `'ann'` from `'ANN'`, but a `DISTINCT` on `citext` merges them. Thus the rule removes a `DISTINCT` or `GROUP BY` only when each item of the select list is a column of a table in the subquery's own `FROM`, and the catalog knows the column's type. The type must be a built-in type that can be hashed and sorted, or an enum. Its collation, if it has one, must be deterministic. A column is written `name.column`, or as a bare column that exactly one `FROM` table has. The table must be schema-qualified, with no alias that renames its columns.

The rule gives one rewrite for each subquery that it can change. Each rewrite starts from the original query and removes every clause that it can remove from that subquery.

The rule refuses:

- a subquery with a `LIMIT`, `OFFSET`, or `FETCH`, which picks rows by their count and order,
- a subquery with `DISTINCT ON`,
- a subquery whose select list calls a set-returning, aggregate, window, or volatile function, and
- a locking clause, such as `FOR UPDATE`, and any statement that isn't a `SELECT`. QUAACK refuses these queries before any rule runs.

These cases are unsupported in v1:

- a `DISTINCT` or `GROUP BY` of an expression, such as `lower(email)`, or of a `*`,
- a `DISTINCT` or `GROUP BY` of a column that a subquery in `FROM`, a CTE, or a function gives,
- a bare column when the `FROM` also holds something other than a table, or when two tables have that column, as in a `USING` join,
- a `GROUP BY` of only some of the select list's columns, such as a table's primary key, and
- an `IN` subquery that a row is tested against, such as `(a, b) IN (SELECT ...)`. QUAACK refuses these queries before any rule runs.

## Why it can be faster.

A `DISTINCT` or `GROUP BY` makes Postgres plan the subquery on its own and remove its duplicates first, which often means reading all of its rows. Without it, Postgres can merge the subquery into the outer query as a semi-join. A semi-join stops at the first match for each outer row, and it can find matches through an index. Postgres can still remove the duplicates first when that's cheaper, so it only gains plans to choose from. An `ORDER BY` in such a subquery sorts rows that no reader reads in order, and it also keeps Postgres from merging the subquery into the outer query. A `UNION` already removes duplicates, so a `DISTINCT` in one of its arms removes some of them twice.

## What it rests on.

The rule makes no assumption. Its output returns the same rows as its input, on any data that the schema allows. It reads each column's type and collation from the catalog.

## Example.

This query uses an `IN` subquery with `DISTINCT`, as Rails writes `User.where(id: Enrollment.where(course_id: 42).distinct.select(:user_id))`. The `IN` only asks whether a user has an enrollment in the course, so the `DISTINCT` changes nothing.

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
    SELECT
      DISTINCT
      enrollments.user_id
    FROM public.enrollments
    WHERE enrollments.course_id = $1
  )
```

After:

```sql
SELECT users.*
FROM public.users
WHERE
  users.id IN (
    SELECT enrollments.user_id
    FROM public.enrollments
    WHERE enrollments.course_id = $1
  )
```
