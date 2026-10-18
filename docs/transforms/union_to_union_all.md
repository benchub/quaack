# union_to_union_all.

The rule turns a `UNION` into a `UNION ALL` when no two of its rows can be equal: each arm selects a unique, not-null key of its one table, and a tag placeholder that differs from every other arm's.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule changes every `UNION` in one set operation to `UNION ALL`, and keeps the rest of the query as it was. It works on a set operation at any depth, such as a derived table, a CTE, or a subquery. Every set operation in it must be a `UNION` without `ALL`.

Each arm must have this form:

- Its `FROM` is one schema-qualified table, read without `ONLY` and without column aliases.
- It has no `DISTINCT` and no `GROUP BY`.
- Its select list and `ORDER BY` might not call a set-returning function, an aggregate, or a window function, even inside a subquery. A set-returning function can give one row of the table more than once.
- It can have a `WHERE`, an `ORDER BY`, a `LIMIT`, and an `OFFSET`, since those only drop rows.

Each arm's select list must hold every column of a unique, not-null key of its table. Each key column is written `name.column` or bare, alone, or the table's `name.*` or `*` stands for all its columns. An alias, as in `posts.id AS item_id`, is fine. An expression such as `posts.id + 0` doesn't count, and neither does a cast. So no two rows of one arm are equal.

Where a key column stands in the select list, every arm must output a column of its own table, of the same type, such as `bigint` in each. Then the `UNION` casts none of them, and compares them as the key's unique index does. The key's type must be an enum or a built-in type that Postgres can hash and sort, with no collation or a deterministic one.

In one position, every arm's select list must have a tag: a constant, which QUAACK makes a placeholder, maybe with a cast, as in `'post' AS kind` or `'post'::text`. The query must hold that placeholder nowhere else. The rule asks the literal oracle whether the tags all differ, compared the way the `UNION` compares them, in its column's type. So `1` and `1.0` match, since the column is `numeric`. A row of one arm then has another tag than every row of the others. The rule reads no value.

The rule refuses:

- a set operation with a `UNION ALL`, an `INTERSECT`, or an `EXCEPT` in it,
- an arm that joins, or reads a subquery, a CTE, or `VALUES`,
- an arm with no key in its select list, or a key that can be `NULL`, and
- two tags that hold the same literal, or that the `UNION`'s type makes equal.

These cases are unsupported in v1:

- a `UNION` under a `UNION ALL`, as in `(a UNION b) UNION ALL c`,
- a key column whose position holds another type in another arm, such as `int` beside `bigint`, or a constant,
- a key with a nondeterministic collation, even when its unique index uses the same collation,
- a nullable key, even one whose unique index is `NULLS NOT DISTINCT`,
- a table read with `ONLY`,
- an arm whose select list has a subquery that calls an aggregate, such as `(SELECT count(*) FROM comments ...)`, or a window function, and
- arms whose rows differ in some other way, such as a key of each table in its own column, with `NULL` in the others.

The rule gives one rewrite for each set operation that it can take, each one made from the original. The generator's second pass then rewrites two.

## Why it can be faster.

`UNION` must remove duplicate rows, so Postgres sorts or hashes every row that the arms return. A big sort or hash can run out of `work_mem` and spill to temporary files on disk. When no two rows can be equal, that work removes nothing. `UNION ALL` returns the arms' rows as they come. Postgres can also merge a `UNION ALL` of plain arms into the query around it, which it can't do with a `UNION`. A filter on the outer query then reaches each table's indexes. With an `ORDER BY` and a `LIMIT`, Postgres can read each table's index in order and stop after the first rows, instead of reading every row of each table.

## What it rests on.

Each arm's key is unique, and each of its columns is not null. The rule fires only when it can prove this. It states the catalog facts that it relies on as assumptions. As with any other assumption, assumption-check checks them again.

Here it states: `public.submissions (id)` is unique; `public.submissions.id` is not null; `public.enrollments (id)` is unique; `public.enrollments.id` is not null. For a key of several columns, it states that each of its columns is not null.

The tags must also differ. That's no catalog fact, so the rule doesn't state it. The literal oracle checks it on the query's own literals. QUAACK's literal sets change a placeholder only where it's compared with a column, so each one keeps the tags' literals, and result-comparison runs the rewrite with them. An app that fills a tag from a variable, not a constant, could send two that match. That's unsupported in v1, and the report doesn't say so.

## Example.

This query is a student's recent activity: their submissions and their enrollments, each tagged with its kind, as an app's feed might merge them. Each arm selects its table's primary key, and the two tags differ. Thus no two rows are equal, and the `UNION` removes nothing.

QUAACK replaces each constant with a placeholder, such as `$1`, before any rule runs. Thus the example shows the constants as placeholders. Here `$1` is `'Submission'` and `$3` is `'Enrollment'`. The rule made this "after" on Postgres 18, from these tables:

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
SELECT $1 AS item_type, submissions.id AS item_id, submissions.workflow_state
FROM public.submissions
WHERE submissions.user_id = $2
UNION
SELECT $3, enrollments.id, enrollments.workflow_state
FROM public.enrollments
WHERE enrollments.user_id = $4
```

After:

```sql
SELECT $1 AS item_type, submissions.id AS item_id, submissions.workflow_state
FROM public.submissions
WHERE submissions.user_id = $2
UNION ALL
SELECT $3, enrollments.id, enrollments.workflow_state
FROM public.enrollments
WHERE enrollments.user_id = $4
```
