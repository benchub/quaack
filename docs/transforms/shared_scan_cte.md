# shared_scan_cte.

A table read more than once in the top-level FROM is read once, by a MATERIALIZED CTE of the WHERE and inner-join ON conjuncts every copy shares.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

A table read more than once in the top-level `FROM`, each copy with the same filter, is read once: `WITH quaack_scan_of_<table> AS MATERIALIZED (SELECT * FROM <schema>.<table> WHERE <shared conjuncts>)`, and each copy reads that CTE under its old alias. A copy's conjuncts are the top-level conjuncts of the `WHERE` and of each inner join's `ON` that read only that copy's columns, qualified by its alias, with no subquery. A conjunct is shared when every copy has it with its own alias in place of the others'. The literal oracle decides whether two placeholders match; no value is read. Shared conjuncts leave every copy and go in the CTE, with the first copy's placeholders. Every other conjunct stays where it was, and an `ON` left empty becomes `ON true`. It runs after `transitive_predicate_copy`, which can give the copies the conjuncts they share. It works only on plain tables in the top-level `FROM`, and only when every top-level `FROM` item has a name, so an aliased join can't hide a copy. It refuses a table with a copy on an outer join's nullable side, a query that already has a CTE of that name at any depth, a CTE body that calls a volatile function, and a query that reads a copy's whole row, other than as `copy.*` in the select list, since the CTE's row type isn't the table's. A name longer than Postgres keeps fails the faithful deparse. Postgres must be able to prepare the rewrite, so a query that names a copy's system column, such as `ctid`, or whose `GROUP BY` relied on the table's primary key, is refused. Reading once isn't always faster, since the CTE hides the table's indexes from the copies' own filters and join conditions; plan-pruning onward decide. plan-pruning's index search covers the CTE's own scan of the base table, as index-from-query does any CTE body.

## What it rests on.

No assumption. Its output returns the same rows as its input on any data the schema allows.

## Example.

A self-join that reads `enrollments` twice, each copy with the same `workflow_state` filter. The rule reads the table once, in a CTE, and both copies read that.

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
