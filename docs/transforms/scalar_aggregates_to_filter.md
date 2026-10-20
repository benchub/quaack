# scalar_aggregates_to_filter.

The rule turns two or more scalar aggregate subqueries over one table into one pass over it, with a `FILTER` for each.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

A dashboard often asks for several numbers from one table, each as its own subquery in the select list, such as `(SELECT count(*) FROM t WHERE t.state = 'a')`. The rule adds one derived table that computes all of them, `(SELECT count(*) FILTER (WHERE t.state = 'a') AS a_1, ... FROM t WHERE s) quaack_aggs_1`, and points each subquery at its column. The derived table goes in the `FROM` as a comma item, or is the whole `FROM` if there was none.

The derived table's `WHERE` holds the conditions that every subquery shares. Each subquery's `FILTER` holds the rest of its conditions, in the order written. A subquery with nothing left gets no `FILTER`. Each output keeps the name Postgres gave it.

A subquery takes part when it's a whole select-list item and it:

- reads one plain table, with no join,
- selects one aggregate call, with no `FILTER`, `WITHIN GROUP`, or window of its own, and
- has no `GROUP BY`, `HAVING`, `DISTINCT`, `ORDER BY`, `LIMIT`, `OFFSET`, `WITH`, set operation, or subquery.

The rule refuses:

- a subquery that reads the outer query, which Postgres can't prepare once it's moved,
- a `SELECT` with a bare `*`, a `GROUP BY`, a `HAVING`, a `WINDOW`, an aggregate outside the subqueries, or a set operation,
- a `SELECT` with no `FROM` but a `WHERE`,
- a shared condition that could raise an error, which stays in each subquery's `FILTER` instead,
- with a `FROM`, a subquery whose conditions could raise, or whose aggregate isn't `count`, `sum`, `avg`, `min`, `max`, `bool_and`, `bool_or`, or `every` over `*` or a bare column, and
- a query that might call a volatile function.

A condition can't raise when it's a comparison, an `IN` list, or an `IS NULL` of columns, constants, and placeholders, or an `AND`, `OR`, or `NOT` of those. These cases are unsupported in v1:

- a subquery inside another expression, such as `coalesce((SELECT ...), 0)`, and
- subqueries in a nested query. The rule only rewrites the top-level query.

## Why it can be faster.

Postgres runs each uncorrelated scalar subquery as its own plan, so three counts of one table scan it three times. The rewrite scans it once, and each aggregate only counts the rows that pass its `FILTER`. When the subqueries share a condition, such as a date range, that condition becomes the derived table's `WHERE`, so one index scan can serve all of them.

## Why Postgres doesn't do this itself.

The planner plans each uncorrelated subquery in the select list as its own init plan, which runs once. It doesn't compare subqueries to find ones that read the same table, so it never merges them into one scan. Merging needs the checks this rule makes, since a shared condition then runs on rows that some subqueries never read.

## What it rests on.

The rule makes no assumption. Its output returns the same rows as its input, on any data that the schema allows. The derived table has no `GROUP BY`, so it always has exactly one row, and a comma join with one row changes no row count. Each aggregate reads exactly the rows its subquery read, so it gives the same value, also over no rows: `count` gives 0 and the others give `NULL`, both ways. Postgres checks a `FILTER` before it computes an aggregate's arguments, so an argument only runs on the rows its subquery read.

An error is the one thing that could differ. A shared condition runs on every row of the table, before any subquery's own conditions. So the rule only shares a condition that can't raise. With a `FROM`, the original never runs a subquery when the `FROM` gives no rows, but the rewrite may still run the derived table. So with a `FROM`, every condition and aggregate must be one that can't raise.

## Example.

This query fills a course dashboard: the submitted count, the graded count, and the mean graded score.

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
```sql
SELECT enrollments.course_id, count(DISTINCT enrollments.user_id) AS students

Before:

```sql
SELECT
  (SELECT count(*) FROM public.submissions
   WHERE submissions.course_id = $1 AND submissions.workflow_state = $2) AS submitted,
  (SELECT count(*) FROM public.submissions
   WHERE submissions.course_id = $3 AND submissions.workflow_state = $4) AS graded,
  (SELECT avg(submissions.score) FROM public.submissions
   WHERE submissions.course_id = $5 AND submissions.workflow_state = $6) AS mean_score
```

After:

```sql
SELECT quaack_aggs_1.a_1 AS submitted, quaack_aggs_1.a_2 AS graded, quaack_aggs_1.a_3 AS mean_score
FROM
  (
    SELECT
      count(*) FILTER (WHERE submissions.workflow_state = $2) AS a_1,
      count(*) FILTER (WHERE submissions.workflow_state = $4) AS a_2,
      avg(submissions.score) FILTER (WHERE submissions.workflow_state = $6) AS a_3
    FROM public.submissions
    WHERE submissions.course_id = $1
  ) quaack_aggs_1
```
