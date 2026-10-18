# distinct_join_to_exists.

This rule rewrites a SELECT DISTINCT over a join that reads only one table, when its columns include a unique, not-null key of that table. The result is that table alone, with an EXISTS on the other tables, and no DISTINCT.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

`SELECT DISTINCT` of one table's columns over a join becomes that table with `EXISTS` on the other tables, and no `DISTINCT`. This page calls that table the kept table. The select list and `ORDER BY` read only the kept table. They can hold its columns, its `*`, or expressions of them, such as a `COLLATE`, a cast, or a function call. A column must be written `t.col`, or as a bare column that only the kept table has. No call can be volatile, set-returning, an aggregate, or a window function.

All the joins are inner joins. The other tables go in one `EXISTS`, together with every condition that reads them.

A condition can hold a subquery, such as `t.id IN (SELECT ...)` or `NOT EXISTS (...)`, if the condition reads only the kept table. That condition stays in the `WHERE` unchanged. The subquery must obey these limits:

- Its `FROM` holds only schema-qualified tables, with no `ONLY`, no alias that renames columns, and no join.
- It has no `WITH` or `UNION`.
- Each column that it reads from outside itself must be a column of the kept table, because the other tables are gone.
- It cannot read the whole row of the kept table, as `a.*`.

The rule does not fire on a subquery in the select list, `ORDER BY`, `LIMIT`, or `OFFSET`.

The rule keeps `ORDER BY`, `LIMIT`, and `OFFSET` unchanged. If there is a `LIMIT` or `OFFSET`, the `ORDER BY` must hold every column of the key, so that the order is total. Each key column can be written as `t.col` or as a bare name (`ORDER BY id LIMIT 20`).

A bare name counts only when it is the key's column. For this, every select-list column with that name must be that column. If the select list has an unaliased expression, Postgres might give it the name of a column, so the rule refuses bare names. The kept table's key is unique, so two of its rows never tie on the key. Thus a bare name that is the key's column orders exactly as `t.col` does.

When a call names a schema, the rule matches the function or operator by that schema. When the call names no schema, the rule refuses if any schema has a set-returning, aggregate, or window function with that name. The rule also refuses when the key's column has a nondeterministic collation that its unique index does not share. In that case, `DISTINCT` would combine rows that the index keeps separate.

## Why it can be faster.

A join can match one row to many. If a user has five enrollments in the course, the join produces that user five times, and `DISTINCT` then has to sort or hash every row to throw the extra copies away. `EXISTS` asks a simpler question: does at least one match exist? Postgres can stop looking at the first match, and it never builds the duplicates, so there's nothing to clean up. The key in the select list is what guarantees the two forms give the same rows, since each kept-table row appears exactly once either way.

## What it rests on.

The select list holds every column of a unique key of the kept table, and each of these columns is not null. The key can have several columns. The rule fires only when it can prove this. It states the catalog facts that it relies on as assumptions. As with any other assumption, assumption-check checks them again.

Here it states: `public.users (id)` is unique; `public.users.id` is not null. For a key of several columns, it states that each column is not null.

## Example.

This query uses `SELECT DISTINCT` over a join. The join only filters `users`. The select list holds `users.id`, the primary key. Thus `EXISTS` gives the same rows with no `DISTINCT`.

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
SELECT
  DISTINCT
  users.*
FROM
  public.users
  JOIN public.enrollments ON enrollments.user_id = users.id
WHERE enrollments.course_id = $1
```

After:

```sql
SELECT users.*
FROM public.users
WHERE
  EXISTS (
    SELECT 1
    FROM public.enrollments
    WHERE
      enrollments.user_id = users.id
      AND enrollments.course_id = $1
  )
```
