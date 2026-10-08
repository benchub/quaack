# or_to_union.

An OR whose arms read different tables or subqueries becomes a UNION of one query per arm, which the rest of the query reads in place of its tables.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

A top-level `OR` whose arms read different tables or subqueries becomes a `UNION` of one query per arm: the query's `FROM` and `WHERE` with only that arm in the `OR`'s place. Each arm selects the columns the rest of the query uses and a key of every `FROM` table. The query then reads the `UNION` in place of its tables, so its select list, aggregates, `DISTINCT`, `ORDER BY`, and `LIMIT` apply to the whole `UNION`.

It leaves a query alone when:

- It has `GROUP BY`, `HAVING`, a window function, `DISTINCT ON`, a locking clause, `WITH`, or `INTO`.
- Its `FROM` has an outer join, a `NATURAL` join, a join with `USING`, a join with an alias, or an item that isn't a schema-qualified table. A table read with `ONLY`, or under an alias that renames its columns, counts too.
- Outside the `WHERE`, it has a subquery, in the select list or the `ORDER BY`.
- Outside the `WHERE`, a column isn't written `name.column`, such as an unqualified column or a bare `*`, or the `ORDER BY` names an output column. In the `OR`'s arms, outside their subqueries, every column must be written `name.column` too.
- A select-list entry with no `AS` has a column in it but isn't a column, a function call, or an operator, such as a cast, a `COALESCE`, or a `CASE` over a column. A cast takes its name from its column, which the `UNION` renames, so the rule leaves all of these alone.
- It uses a column of a type `UNION` can't compare, such as `json`.
- An arm has a `LIKE` or `ILIKE` and the database has a column, domain, or range with a nondeterministic collation, or the `LIKE` names a collation with `COLLATE`. `ILIKE` raises on a nondeterministic collation, and so does `LIKE` before Postgres 18, only as it reads a row.
- An arm has a `LIKE` or `ILIKE` whose constant pattern has a backslash in it, and `standard_conforming_strings` is off for the run. The server then reads the backslashes otherwise than QUAACK's parser does. Unsupported in v1: QUAACK reads every query as `standard_conforming_strings = on` reads it.
- An arm of the `OR`, its subqueries included, has something that can raise an error on some rows: a cast, a function call, or an operator other than a comparison (such as `/` or `%`) over a column, an index into a column, or a subquery used as a value. One with no column in it, such as `'10'::int`, is fine. So is a `LIKE` or `ILIKE` whose pattern is a parameter, or a string constant that doesn't end in the escape character, `\`. A column pattern may end in it, and Postgres raises on that only when it reads a row, so a column pattern keeps the `OR` from splitting, and so do `NULL` and `ESCAPE`.

That last refusal matters because Postgres runs an `OR`'s arms in order and stops at the first true one. In `o.vip OR i.total / i.qty > 10`, the first arm keeps the division from running on a VIP's rows, where `i.qty` may be 0. Split, each arm runs on its own, and the division would raise where the original returns rows.

A parameter pattern's value isn't something the rule sees. If the app passes a pattern that ends in a lone backslash, such as `ab\`, the rewrite raises where the original might not, since the original's other arm can skip the `LIKE` for a row and the `UNION`'s branch can't. In `o.vip OR i.val LIKE $1`, the original returns a VIP's rows without running the `LIKE`, while the branch with `i.val LIKE $1` runs it on every row and raises "LIKE pattern must not end with escape character". QUAACK makes every constant a parameter before the rule runs, so this is how most `LIKE` arms reach the rule. QUAACK accepts that risk rather than refuse every `LIKE` arm.

The rule reads only the parse tree, so it doesn't see the casts the planner adds when an operator's two sides have different types. `n.amount = r.ratio`, a `numeric` against a `real`, compares as `double precision`, and an amount too big for one, such as `1e400`, raises. The rule splits that `OR` anyway, so such an arm can raise in the `UNION` where the original returns rows.

Arms with no subquery that read the same tables stay together in one query of the `UNION`, as an `OR` in their order. So `i.qty = 0 OR i.total > 10 OR o.vip` becomes two queries, not three.

## What it rests on.

A unique, not-null key of every `FROM` table, one column each, so `UNION` removes exactly the rows both arms return. The rule fires only when it can prove this, and it states the catalog facts it relies on as assumptions, which assumption-check checks again like anyone else's.

Here it states: `public.users (id)` is unique; `public.users.id` is not null.

## Example.

An `OR` of two `IN` subqueries on different tables. The rule makes one query per arm and reads their `UNION`. `users.id` is the primary key, so `UNION` drops only a user both arms return.

QUAACK replaces each constant with a placeholder, such as `$1`, before any rule runs, so the example shows them that way. The rule made this "after" on Postgres 18, from these tables:

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
SELECT users.id, users.name
FROM public.users
WHERE
  users.id IN (
    SELECT enrollments.user_id
    FROM public.enrollments
    WHERE enrollments.course_id = $1
  ) OR users.id IN (
    SELECT submissions.user_id
    FROM public.submissions
    WHERE submissions.assignment_id = $2
  )
```

After:

```sql
SELECT arms_1.id_1 AS id, arms_1.name_1 AS name
FROM
  (
    SELECT users.id AS id_1, users.name AS name_1
    FROM public.users
    WHERE
      users.id IN (
        SELECT enrollments.user_id
        FROM public.enrollments
        WHERE enrollments.course_id = $1
      )
    UNION
    SELECT users.id AS id_1, users.name AS name_1
    FROM public.users
    WHERE
      users.id IN (
        SELECT submissions.user_id
        FROM public.submissions
        WHERE submissions.assignment_id = $2
      )
  ) arms_1
```
