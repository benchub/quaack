# unused_join_removal.

The rule removes an inner join to a table that the query reads nowhere else. The join must be on a validated foreign key, and all columns of that key must be not null.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule removes an inner join to a table that the query reads nowhere else. It works in any `SELECT` at any depth. The join must have one of these two forms:

- An inner `JOIN` with no alias, `NATURAL`, or `USING`, where one side is the joined table.
- The joined table is an item of a comma-separated `FROM`, and the join's equalities are conjuncts at the top level of its `WHERE`.

Every condition of that `ON`, or every such conjunct, must be a plain `=` between two columns written `name.column`. One column is of the joined table. The other column is of one joining table, and no outer join on its side can fill that table with `NULL`. The rule removes these conditions with the table. If the `WHERE` becomes empty, the rule removes it too.

Postgres removes an unused left join to a unique key, but it never removes an inner join, because an inner join can drop rows. With the foreign key, the inner join cannot drop rows. The rule needs all of these conditions:

- The foreign key pairs exactly the joining columns with the joined columns.
- The foreign key is validated and not deferrable, and its triggers are enabled.
- Both tables are plain tables, with no inheritance parent or child, so neither is a partition or a partitioned table.
- The joined table has no row-level security, because the join would filter by it.
- Each pair of columns has one type, whose `=` is the key's own operator, and no nondeterministic collation.

The query must read the joined table nowhere else. Thus:

- No column reference that might resolve to the joined table names it, other than in the conditions that the rule removes.
- No bare column inside the `SELECT` that joins the table has the name of one of the table's columns.

Only references inside that `SELECT` might resolve to the joined table. A nested `SELECT` can have its own `FROM` that binds the name first. Then a `name.column` or `name.*` in its select list, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `WINDOW`, or `DISTINCT ON` cannot resolve to the joined table. Thus another `UNION` branch, or a subquery such as Rails' `IN (SELECT users.id FROM users ...)`, can use the name again. A join with an alias hides the names inside it.

The `SELECT` that joins the table has no bare `*`. Any other condition on the joined table blocks the rule. The rule also refuses a query with a locking clause, or with a `NATURAL` or `USING` join anywhere.

These cases are unsupported in v1:

- a nullable joining column that the `WHERE` requires to be non-null,
- a joined table read with `ONLY`, and
- a `JOIN` whose `ON` holds a condition that does not read the joined table.

## What it rests on.

The rule needs a foreign key from the joining columns to the joined columns. Each joining column must also be not null. The rule fires only when it can prove this. It states the catalog facts that it relies on as assumptions. As with any other assumption, assumption-check checks them again.

Here it states: `public.submissions (assignment_id)` references `public.assignments (id)`; `public.submissions.assignment_id` is not null.

## Example.

This example has a join to a table that the query never reads. Such a join can come from a scope. The foreign key on the not-null `submissions.assignment_id` says that every submission has exactly one assignment. Thus the join does not drop a row, and it does not repeat a row.

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
SELECT submissions.*
FROM
  public.submissions
  JOIN public.assignments ON assignments.id = submissions.assignment_id
WHERE submissions.user_id = $1
```

After:

```sql
SELECT submissions.*
FROM public.submissions
WHERE submissions.user_id = $1
```
