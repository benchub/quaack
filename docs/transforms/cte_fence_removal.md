# cte_fence_removal.

A CTE written AS MATERIALIZED, or one the query reads more than once, becomes AS NOT MATERIALIZED, so the planner can push each reader's conditions into it.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

Postgres runs a CTE on its own and stores its rows in two cases:

- The CTE is written `AS MATERIALIZED`.
- The CTE is plain, and the query reads it more than once.

The rule writes such a CTE `AS NOT MATERIALIZED`, and changes nothing else. Postgres then plans the body of the CTE as a subquery, in each place that the query reads it. It can push the conditions of each reader into that subquery, down to the tables of the body.

The rule gives one rewrite for each CTE that it can change, at any depth of the query. Each rewrite changes only that CTE. The rule leaves these CTEs alone, because Postgres doesn't store them:

- A CTE that is already `NOT MATERIALIZED`.
- A plain CTE that the query reads once. Postgres already plans it as a subquery.
- A CTE that the query never reads.

The rule refuses these cases:

- A query with a `RECURSIVE` `WITH`, or a data-modifying CTE, anywhere in it.
- A body that calls a volatile function. Stored, such a body runs once. As a subquery, it can run once for each read.
- A CTE whose name starts with `quaack_`. `shared_scan_cte` gives its CTEs such names, and this rule would undo that rule's rewrite.

Two more refusals keep the rewrite from returning other rows, or raising an error where the original doesn't. The next two sections give them.

## A body that runs more than once.

Stored, the body runs once, and every read gets the same rows. Not stored, the body runs once for each read. A read inside a subquery expression, a `LATERAL` subquery, or the body of another CTE can also run the body more than once. Each run can push its own conditions into the body, so each run can have its own plan, and read the rows of the table in its own order.

So when the body can run more than once, the rule needs a body whose rows can't depend on that order. It refuses a body with any of these, at any depth:

- `LIMIT`, `OFFSET`, or `FETCH FIRST`, which keep the rows that come first.
- `DISTINCT`, `DISTINCT ON`, `GROUP BY`, or a `UNION`, `INTERSECT`, or `EXCEPT` without `ALL`, or an `INTERSECT ALL` or `EXCEPT ALL`. Each keeps one row of the rows that it counts as equal. Two values can be equal but differ, such as `1.0` and `1.00`, so each run can keep another one.
- An aggregate, window, or set-returning function. `array_agg`, `row_number`, and a sum of floats all depend on the order.

The same holds for each CTE that the body reads, at any depth. If Postgres doesn't store that CTE, the body runs it again in each run.

When the query reads the CTE once, outside all of those places, the body runs once. The rewrite then reads it as if the query had been written with a subquery in that place. So the rule takes a body that groups or limits when the query reads it once there.

## A condition that can raise.

Stored, the CTE gives each reader only the rows that its body keeps. So a condition of a reader runs only on those rows. Not stored, Postgres can push the condition down to the tables of the body. There it can run before the `WHERE` or the joins of the body drop a row.

Take a body that joins `orders` to `users`, as `SELECT o.id, o.total, o.qty FROM public.orders o JOIN public.users u ON u.id = o.user_id`, and a reader that filters on `m.total / m.qty > 3`. Stored, the division runs only on orders that have a user. `NOT MATERIALIZED`, it can run on every order. If an order without a user has a `qty` of 0, the rewrite raises "division by zero" where the original returns rows.

So the rule refuses a query where a condition that can raise could reach the tables of the body. A condition can raise when it holds a cast, a function call, or an operator other than a comparison (such as `/` or `%`) over a column, an index into a column, or a subquery used as a value. That's the check that `or_to_union` uses for the arms of an `OR`. The rule looks at these places, at any depth:

- Each condition of a `SELECT` outside the body. That's each conjunct of its `WHERE`, its `HAVING`, or the `ON` of a join, and each function in its `FROM`. A condition whose every column is written `name.column`, where `name` is a plain table in the `FROM` of that `SELECT`, off the nullable side of every outer join, reads only the rows of that table. The rewrite doesn't change those rows, so such a condition doesn't count.
- Each expression in the select list or the `VALUES` of a `SELECT`, inside the body or outside it, except the `SELECT`s whose columns are the output of the query. A condition on a column of such a `SELECT` reads the expression in its place. So `m.ratio > 3` can raise when the body computes `m.ratio` as `o.total / o.qty`. Unsupported in v1: the rule doesn't track which columns the conditions read, so it refuses such an expression even when no condition reads its column.

An aggregate or a window call doesn't count. It runs on the rows of its own query, after every condition of that query has passed, and Postgres never pushes down a condition that reads one. So `HAVING sum(m.total / m.qty) > 3` is fine. The conditions of the body itself don't count either. They run on the same rows of its tables, stored or not.

`LIKE` and `ILIKE` follow `or_to_union`'s check too. A `LIKE` whose pattern is a parameter counts as safe, though the rule can't see the parameter's value. If the app passes a pattern that ends in a lone backslash, Postgres raises an error the first time it runs the `LIKE`. Pushed down, the `LIKE` can run on a row that the body drops. So if the body keeps no rows, the rewrite can raise where the original returns none. QUAACK accepts that risk, as it does for `or_to_union`.

## Why it can be faster.

A CTE that Postgres stores acts as a fence. Postgres runs the body by itself, keeps every row it makes, and only then lets the rest of the query filter them. If the body reads a large table and the reader wants only a few rows, such as one customer's orders, Postgres still reads and stores the whole result first. `NOT MATERIALIZED` takes the fence away. Postgres treats the body like a subquery, so it can move the reader's filter into the body and use an index on the table to find just the rows that the reader wants. The cost is that a CTE that the query reads more than once now runs once for each read, so QUAACK measures the rewrite rather than assuming it helps.

## Why Postgres doesn't do this itself.

Since Postgres 12, the planner inlines a plain CTE that the query reads once, but it stores one the query reads more than once. Inlining such a CTE can run its body once for each read, so Postgres doesn't risk it, and it doesn't cost both plans to choose. It always honors `AS MATERIALIZED`, since that's how a query asks for the fence. Inlining also isn't always safe, as the sections above show, and the planner doesn't make those checks. QUAACK makes them, and then measures both forms.

## What it rests on.

No assumption. Its output returns the same rows as its input on any data the schema allows.

## Example.

A `MATERIALIZED` CTE of active enrollments, which the query reads once, for one course. The rule makes it `NOT MATERIALIZED`, so the course filter can reach the `enrollments` table.

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
WITH active_enrollments AS MATERIALIZED (
  SELECT enrollments.id, enrollments.user_id, enrollments.course_id
  FROM public.enrollments
  WHERE enrollments.workflow_state = $1
)
SELECT active_enrollments.id, active_enrollments.user_id
FROM active_enrollments
WHERE active_enrollments.course_id = $2
```

After:

```sql
WITH active_enrollments AS NOT MATERIALIZED (
  SELECT enrollments.id, enrollments.user_id, enrollments.course_id
  FROM public.enrollments
  WHERE enrollments.workflow_state = $1
)
SELECT active_enrollments.id, active_enrollments.user_id
FROM active_enrollments
WHERE active_enrollments.course_id = $2
```
