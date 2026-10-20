# correlated_aggregate_to_join.

This rule rewrites a `WHERE` condition that compares with a correlated `avg`, `sum`, `min`, or `max` subquery into a join to a derived table that computes the aggregate once for each group.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule looks for a top-level condition of the query's `WHERE` written `e op (SELECT agg(s.x) FROM s WHERE s.k = t.c AND ...)`, with the subquery on either side. `op` is `=`, `<>`, `<`, `<=`, `>`, or `>=`. The rule adds `(SELECT s.k, agg(s.x) AS quaack_agg FROM s WHERE ... GROUP BY s.k) quaack_agg_1` to the query's `FROM`, adds `quaack_agg_1.k = t.c` to its `WHERE`, and puts `quaack_agg_1.quaack_agg` where the subquery was. Each correlation becomes one column of the `GROUP BY`. The subquery's other conditions move into the derived table. The rule rewrites every such condition in one rewrite, each with its own derived table.

`avg`, `sum`, `min`, and `max` give `NULL` over no rows. So a row of `t` with no group, or with a `NULL` in `t.c`, gets a `NULL` aggregate in the original, and the comparison is `NULL`. In the rewrite, that row has no partner in the derived table. The `WHERE` drops the row either way. Each key has one group, so no row repeats.

The rule does not change these:

- A subquery anywhere but a top-level condition of the outer query's `WHERE`, such as one in the select list, under an `OR`, or in a `CASE`. There, a row with no group keeps its `NULL` in the original, but the join would drop the row.
- `count`, which gives 0 over no rows, not `NULL`.
- An aggregate of anything but a column of the subquery's table, written `name.column`, or one with `DISTINCT`, `FILTER`, `ORDER BY`, or `OVER`.
- A `sum` or `avg` of a column that isn't `smallint`, `integer`, `bigint`, or `numeric`. The derived table computes every group, including groups the original never reads, and a `sum` of `double precision` or `interval` can overflow on one of them.
- A subquery that reads more than one table, or that has `GROUP BY`, `HAVING`, `DISTINCT`, `ORDER BY`, `LIMIT`, a window, a set operation, or a subquery of its own.
- A subquery condition that is neither `s.k = t.c` (either way round) nor a condition that reads only the subquery's table with every column written `name.column`. A bare column could be the outer query's. `t` must be a plain table of the outer query's own `FROM`.
- A correlation whose two columns have different types or collations, a type that can't hash and sort as its equality compares, or a nondeterministic collation.
- A subquery condition that can fail on some rows, such as a cast like `s.note::int`, a function call, or arithmetic like `/`. The derived table checks its conditions on every row of the table, not just the rows of the groups the original reads.
- An outer select list with a bare `*`, which would also show the derived table's columns.
- A query that calls a volatile function anywhere.

## Why it can be faster.

Postgres runs a correlated subquery once for each outer row that reaches it. Each run finds that row's group and computes its aggregate again, so a group of 50 rows is read 50 times when 50 outer rows share it. The derived table reads the table once, groups it with a hash or a sort, and computes each group's aggregate once. Postgres then joins it to the outer rows with a hash join, or another join that fits.

## Why Postgres doesn't do this itself.

The planner turns `EXISTS` and `IN` subqueries into joins, but it leaves a scalar subquery used as a value, such as `(SELECT avg(...) ...)`, as a subplan that runs once for each outer row. Turning it into a join needs reasoning the planner doesn't do: that the aggregate gives `NULL` over no rows, that the comparison sits where a `NULL` drops the row just as a missing join partner does, and that computing every group can't raise on a group the original never reads.

## What it rests on.

Nothing. These aggregates give `NULL` over no rows by definition, and a `GROUP BY` gives one row per key, so the rule needs no fact from the catalog, and it states no assumptions.

## Example.

This query keeps the graded submissions that scored above their assignment's average graded score. The rewrite computes each assignment's average once.

QUAACK replaces each constant with a placeholder, such as `$1`, before any rule runs. Thus the example shows the constants as placeholders. Here `$1` and `$2` are both `'graded'`. The rule made this "after" on Postgres 18, from these tables:

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
SELECT submissions.id, submissions.user_id
FROM public.submissions
WHERE
  submissions.workflow_state = $1
  AND submissions.score > (
    SELECT avg(s2.score)
    FROM public.submissions s2
    WHERE
      s2.assignment_id = submissions.assignment_id
      AND s2.workflow_state = $2
  )
```

After:

```sql
SELECT submissions.id, submissions.user_id
FROM
  public.submissions,
  (
    SELECT s2.assignment_id, avg(s2.score) AS quaack_agg
    FROM public.submissions s2
    WHERE s2.workflow_state = $2
    GROUP BY s2.assignment_id
  ) quaack_agg_1
WHERE
  submissions.workflow_state = $1
  AND submissions.score > quaack_agg_1.quaack_agg
  AND quaack_agg_1.assignment_id = submissions.assignment_id
```
