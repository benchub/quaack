# distinct_key_removal.

The rule removes the `DISTINCT` of a `SELECT DISTINCT` whose rows can't repeat: the select list holds a unique, not-null key of its first table, and each join matches at most one row.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule removes a plain `DISTINCT`. It works in any `SELECT` at any depth, such as a derived table, a subquery, or a `UNION` arm. It keeps the rest of the query as it was, including `ORDER BY`, `LIMIT`, and `OFFSET`. With `DISTINCT`, every `ORDER BY` item is in the select list, so the rows it orders are the same without it.

This page calls the first table in the `FROM` the first table. The `FROM` must have this form:

- It's one schema-qualified table, read without `ONLY` and without column aliases.
- Any number of inner or left joins follow it, each to one such table. A join can't have an alias, and it can't be nested on the right, as `a JOIN (b JOIN c ON ...) ON ...` is.
- Every table has a name of its own.

Each join's `ON` must pair every column of a unique key of the joined table with a column of a table before it. Each pair is a plain `=` between two columns written `name.column`, at the top level of the `ON`'s `AND`. The `ON` can hold other conditions too, since they only filter. So each row of the first table gets at most one row of each joined table. An inner join can drop the row, and a left join keeps it with `NULL`s, but neither repeats it.

The two columns of each pair must have one type, or be two of `smallint`, `integer`, and `bigint`, as an `integer` foreign key to a `bigint` primary key is in older Rails schemas. The pair's `=` must be the operator of the type's default btree family, which the key's unique index also uses. Neither column can have a nondeterministic collation. Otherwise one row could be `=` to two rows of the joined table.

The select list must hold every column of a unique, not-null key of the first table. Each key column is written `name.column`, alone, or the table's `name.*` stands for all its columns. An alias, as in `posts.slug AS s`, is fine. An expression such as `posts.id + 0` doesn't count. The key's columns can't have a nondeterministic collation. Since each row of the first table gives at most one row, and the key tells those rows apart, no two rows are equal.

The rule refuses:

- `DISTINCT ON`, `GROUP BY`, and a locking clause such as `FOR UPDATE`,
- a select list that might call a set-returning function, an aggregate, or a window function, even inside a subquery, and
- a comma join, a `CROSS JOIN`, a `RIGHT` or `FULL` join, and a `NATURAL` or `USING` join.

With no `GROUP BY`, an aggregate or a `HAVING` makes the whole `SELECT` one group. Postgres then refuses the key's bare column in the select list, so the rule needs no check of its own for them.

These cases are unsupported in v1:

- a join whose key is paired with a constant or a parameter, as in `ON users.id = $1`,
- a join whose pair has two types other than two integer types, such as `integer` and `numeric`, or whose `=` names its schema,
- a `UNION`, `INTERSECT`, or `EXCEPT` arm whose select list holds a bare constant or parameter, as in `SELECT DISTINCT posts.id, 'Post' AS kind ... UNION ALL ...`. With `DISTINCT`, Postgres makes that constant `text`. Without it, the constant takes the other arm's type, which may compare otherwise, as `citext` does,
- a has_one join on a unique foreign key that's nullable, such as `LEFT JOIN profiles ON profiles.user_id = users.id`, since the `unique` assumption also requires the key not null,
- a key column with a nondeterministic collation, even when its unique index uses the same collation,
- a select list with a subquery that calls an aggregate, such as `(SELECT count(*) FROM comments ...)`,
- a table read with `ONLY`, and
- a nullable key, even one whose unique index is `NULLS NOT DISTINCT`.

The rule gives one rewrite for each `SELECT` that it can take, each one made from the original. The generator's second pass then removes two.

## Why it can be faster.

`DISTINCT` makes Postgres sort or hash every row the query produces, just to find duplicates. When the rows can't repeat, that work removes nothing. A big sort can run out of `work_mem` and spill to temporary files on disk, which costs reads and writes of its own. Without the `DISTINCT`, Postgres returns the rows as the join makes them. With an `ORDER BY` and a `LIMIT`, it can also stop as soon as it has enough rows, without sorting by every selected column.

## What it rests on.

The select list holds every column of a unique key of the first table, and each of these columns is not null. Each joined table has a unique key that its join pairs. The rule fires only when it can prove this. It states the catalog facts that it relies on as assumptions. As with any other assumption, assumption-check checks them again.

Here it states: `public.submissions (id)` is unique; `public.submissions.id` is not null; `public.assignments (id)` is unique; `public.courses (id)` is unique. For a key of several columns, it states that each column of the first table's key is not null.

## Example.

This query has a `.distinct` that a Rails scope added, for a filter that might join a has-many association. Here every join is to one row: each submission has one assignment, and at most one course. The select list holds `submissions.id`, the primary key. Thus no two rows are equal, and the `DISTINCT` removes nothing.

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
SELECT DISTINCT submissions.*, assignments.title, courses.name
FROM
  public.submissions
  JOIN public.assignments ON assignments.id = submissions.assignment_id
  LEFT JOIN public.courses ON courses.id = submissions.course_id
WHERE submissions.user_id = $1
```

After:

```sql
SELECT submissions.*, assignments.title, courses.name
FROM
  public.submissions
  JOIN public.assignments ON assignments.id = submissions.assignment_id
  LEFT JOIN public.courses ON courses.id = submissions.course_id
WHERE submissions.user_id = $1
```
