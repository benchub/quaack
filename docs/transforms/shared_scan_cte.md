# shared_scan_cte.

When one FROM reads a table more than once, a MATERIALIZED CTE reads it once. The CTE applies the WHERE and inner-join ON conjuncts that every copy shares.

It's one of QUAACK's transform rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

This rule applies when one `FROM` reads a table more than once, and each copy has the same filter. The rule reads the table once, in `WITH quaack_scan_of_<table> AS MATERIALIZED (SELECT * FROM <schema>.<table> WHERE <shared conjuncts>)`. Each copy then reads that CTE under its old alias.

The conjuncts of a copy are the top-level conjuncts of the `WHERE`, and of each inner join's `ON`, that obey all of these conditions:

- They read only the columns of that copy.
- They qualify those columns with the alias of that copy.
- They contain no subquery.

A conjunct is shared when every copy has it, with the alias of that copy in place of the aliases of the other copies. The literal oracle decides whether two placeholders match. No value is read. The shared conjuncts move out of every copy and into the CTE, with the placeholders of the first copy. Every other conjunct stays in its old position. If an `ON` has no conjuncts left, it becomes `ON true`.

The rule runs after `transitive_predicate_copy`, which can give the copies the conjuncts that they share.

The rule looks at each `SELECT` of the query that can have a `WITH` of its own: the query itself, and every subquery and CTE body in it. Each one is its own scope, with its own copies and its own CTE, which goes in the `WITH` of that `SELECT`. A conjunct that reads the outer query stays in its old position, because the CTE cannot read the outer query. The rule leaves a branch of a set operation alone.

In a scope, the rule works only on plain tables. It also works only when every `FROM` item has a name, so that an aliased join cannot hide a copy.

Copies read with `ONLY` share a CTE that reads `ONLY` the table, and the copies then read the CTE without the keyword. They never share a CTE with copies that also read the children of the table, so each kind is its own group.

A copy on the nullable side of an outer join stays on the table, because a `WHERE` conjunct on it would also remove the rows that the join null-extends. The other copies share a CTE without it.

The rule refuses these cases:

- A table with fewer than two copies off every nullable side.
- A query that already has a CTE of that name, at any depth.
- A CTE body that calls a volatile function.
- A query that reads the whole row of a copy, other than as `copy.*` in the select list. The row type of the CTE is not the row type of the table.

If a name is longer than the length that Postgres keeps, the faithful deparse fails.

A `GROUP BY` can name the whole primary key of a copy, and leave the other columns of that copy to the select list, `HAVING`, or `ORDER BY`. Such a query relies on the key, and a CTE has no key. So the rule adds the columns that the query reads to the `GROUP BY`. That splits no group: the key is unique, so every row of a group has the same copy row. The rule takes the key from the catalog, and only when the key cannot be deferred and no inheritance child can repeat it. A `GROUP BY` without the whole key gets nothing added, because a column that it groups only inside an expression, such as `lower(name)`, would split its groups.

Postgres must still be able to prepare the rewrite. Thus the rule refuses a query that names a system column of a copy, such as `ctid`. It also refuses a query whose `GROUP BY` relies on a key that the rule cannot use.

A single read is not always faster, because the CTE hides the indices of the table from the filters and join conditions of the copies. plan-pruning and the steps after it decide if it is faster. The index search of plan-pruning covers the scan of the base table by the CTE, as index-from-query covers any CTE body.

## What it rests on.

No assumption. Its output returns the same rows as its input on any data the schema allows.

## Example.

A self-join that reads `enrollments` two times, with the same `workflow_state` filter on each copy. The rule reads the table once, in a CTE, and both copies read that CTE.

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
SELECT teachers.user_id, students.user_id
FROM
  public.enrollments teachers
  JOIN public.enrollments students ON students.course_id = teachers.course_id
WHERE
  teachers.workflow_state = $1
  AND students.workflow_state = $2
```

After:

```sql
WITH quaack_scan_of_enrollments AS MATERIALIZED (
  SELECT *
  FROM public.enrollments
  WHERE enrollments.workflow_state = $1
)
SELECT teachers.user_id, students.user_id
FROM
  quaack_scan_of_enrollments teachers
  JOIN quaack_scan_of_enrollments students ON students.course_id = teachers.course_id
```
