# subquery_order_removal.

The rule removes an `ORDER BY` from a subquery in `FROM` or a CTE when nothing that reads its rows depends on their order.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule looks at each subquery in a `FROM`, `LATERAL` ones and those in a join included, and at each CTE body. When one of them has an `ORDER BY`, the rule looks at each query that reads its rows. A subquery in `FROM` has one reader, the `SELECT` whose `FROM` holds it. A CTE's readers are all the `SELECT`s that name it in their `FROM`. The rule removes the `ORDER BY` only when every reader is blind to the order of the rows it reads. A reader is blind to that order when it has no window function, no `WINDOW` clause, and no `DISTINCT ON`, and one of these holds:

- It has its own `ORDER BY`. That `ORDER BY` decides the order of its rows, and which rows a `LIMIT` or `OFFSET` keeps.
- It aggregates, with a `GROUP BY` or an aggregate call, and it has no `LIMIT` or `OFFSET`.

A reader with neither returns its rows in the order they arrive. SQL doesn't promise that order, but an app may rely on it, so the rule leaves such a subquery alone.

Each aggregate that a reader calls must give a result that doesn't depend on the order of its input:

- `count`, `bool_and`, `bool_or`, and `every` never depend on it.
- `min` and `max` keep the first of two equal values. So their value must have a type in which equal values look the same. A `numeric` doesn't qualify, since `10` and `10.0` are equal. The type must be an integer, `oid`, `boolean`, `date`, `time`, `timestamp`, `timestamptz`, `uuid`, or `bytea`. It can also be `text`, `varchar`, or `name`, when no column, domain, or range in the database uses a nondeterministic collation, and the query has no `COLLATE`.
- `sum` and `avg` must add integers or a `numeric`. A float's sum rounds differently in another order, and a sum of `interval` or `money` can overflow in one order but not in another.
- Any aggregate with its own `ORDER BY`, `WITHIN GROUP` included, sorts its input itself.

Any other function that a reader calls must give one value per row. A set-returning function, such as `unnest`, makes the rule refuse.

Each of these must be one of `pg_catalog`'s own aggregates, written with a bare name or as `pg_catalog.name`. The rule refuses it when another schema has a function of the same name. A `GROUP BY` and a plain `DISTINCT` also keep one of each group's equal values. So each `GROUP BY` item, and each column of a `DISTINCT`, needs one of the types that `min` and `max` need.

Postgres says what these types are. It can type a reader's values only when the reader is the top-level `SELECT`. QUAACK first types them with each constant left for Postgres to type. Then its literal oracle checks each type again with the constants' own types. A constant such as `1.0` is a `numeric`, so `CASE WHEN ... THEN 1.0 ELSE 1.00 END` is a `numeric` too, and the rule refuses a `GROUP BY` of it.

The rule gives one rewrite for each subquery that it can change. Each rewrite starts from the original query.

The rule refuses:

- a subquery with a `LIMIT`, `OFFSET`, or `FETCH`, which picks rows by their order, or with `DISTINCT ON`, which picks one row of each group by that order,
- a subquery whose select list, `ORDER BY`, or `HAVING` calls an aggregate, window, or set-returning function. With no `GROUP BY`, an aggregate in the `ORDER BY` alone makes the subquery return one row,
- a CTE of a `WITH RECURSIVE`, and a CTE whose name another CTE in the query also has,
- a query that calls a volatile function anywhere, and
- a locking clause, such as `FOR UPDATE`, a data-modifying CTE, and any statement that isn't a `SELECT`. QUAACK refuses these queries before any rule runs.

The rule leaves alone an `IN` subquery and an arm under a `UNION`, `INTERSECT`, or `EXCEPT`. [`subquery_distinct_removal`](subquery_distinct_removal.md) removes their `ORDER BY`.

These cases are unsupported in v1:

- a reader with no `ORDER BY` that doesn't aggregate, even when the query that reads it sorts or aggregates in turn, as in `SELECT count(*) FROM (SELECT * FROM (SELECT ... ORDER BY ...) a) b`, or when it's an `IN` subquery,
- a reader that needs a type for `min`, `max`, `sum`, `avg`, `GROUP BY`, or `DISTINCT` but isn't the top-level `SELECT`, or whose value there is a `*`,
- a `min`, `max`, `sum`, or `avg` of the reader's rows inside a subquery of the reader, and any call inside such a subquery that isn't one of the other aggregates above and doesn't give one value per row, such as an `array_agg` over another table,
- a value of a domain type, even a domain over a type that qualifies,
- a value whose type differs when a constant has no type of its own, such as each column of `VALUES (1), (2)`, which is `text` with untyped constants and `integer` with the real ones, and
- other aggregates whose result doesn't depend on the order of their input, such as `bit_and` or `array_agg(DISTINCT ...)`.

## Why it can be faster.

Postgres can't merge a subquery that has an `ORDER BY` into the query that reads it. So it plans the subquery on its own, reads every column that the `ORDER BY` needs, and sorts all of the subquery's rows before the reader sees any of them. When the reader only counts the rows, or sorts them again, that sort is wasted work, and a big sort can spill to disk. Without the `ORDER BY`, Postgres can merge the subquery into the reader. Then it can count the rows straight from an index, for example, without reading the table at all. A CTE that the query reads twice is still computed once, but it no longer sorts its rows.

## What it rests on.

The rule makes no assumption. SQL never promises a subquery's order to the query that reads it. Each reader that the rule accepts either sets the order of its own rows, or gives results that don't depend on the order of its input. So the output returns the same rows as the input, on any data that the schema allows. Rows that tie on the reader's own `ORDER BY` can come back in another order, and a `LIMIT` can keep other rows of a tie, which SQL allows too. The rule reads the types of the reader's values from Postgres.

## Example.

This query counts a list of submissions by wrapping the list's own SQL, as an app might do to count the pages of a paginated list. The count doesn't depend on the order of the rows, so the `ORDER BY` changes nothing.

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
SELECT count(*)
FROM
  (
    SELECT submissions.*
    FROM public.submissions
    WHERE submissions.assignment_id = $1
    ORDER BY submissions.id DESC
  ) subquery_for_count
```

After:

```sql
SELECT count(*)
FROM
  (
    SELECT submissions.*
    FROM public.submissions
    WHERE submissions.assignment_id = $1
  ) subquery_for_count
```
