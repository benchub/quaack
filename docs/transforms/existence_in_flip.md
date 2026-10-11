# existence_in_flip.

The rule turns an existence check under LIMIT 1 inside out. The table of an uncorrelated IN subquery drives. The remainder of the query becomes an EXISTS that is correlated on the two sides of the IN.

This rule is one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

An existence check is a query with these properties:

- Its select list is all constants. Each constant can have a cast, as in `1::integer`.
- It has `LIMIT 1`.
- It has no `DISTINCT`, `GROUP BY`, `HAVING`, window, or `OFFSET`.

The rule turns an existence check inside out on a top-level `WHERE` conjunct `x IN (SELECT y FROM S WHERE P)`. The result is `SELECT <the same constants> FROM S WHERE P AND EXISTS (SELECT 1 FROM <the original FROM> WHERE <the other conjuncts> AND x = y) LIMIT 1`. Thus `S` drives. A `LIMIT 1` fast-start plan from the other side can be slower than this plan. The original FROM, with its outer joins, moves as one unit into the `EXISTS`. The CTEs of the original stay at the top.

Both queries return a row exactly when some combination of rows passes every predicate with `x = y`. The `IN` and the `=` use the same operator, so a `NULL` matches nothing in either query. The rule needs `LIMIT 1`, because with a larger limit the two queries can return different numbers of rows.

An `ORDER BY` becomes `ORDER BY 1`. Every row is the same constants, so the order has no effect on which row is returned. But result comparison needs a candidate to keep an `ORDER BY` that the original has. Each key must have no `USING`, and must be one of these:

- An output position.
- A column written `name.column` of a plain table in the original FROM, whose type is an enum or a built-in scalar.

The reason for this limit is that a sort can fail at run time. For example, `1 / 0` fails, and a `json[]` or a whole row with a `json` column fails when two rows compare. The original query sorts these rows, but the rewrite would not sort them.

`y` can be an expression with no subquery. A subquery is not permitted, because a bare name in a subquery would see the original FROM first. `y` cannot be a bare constant, alone or under `COLLATE`. `IN` reads such a constant as `text`, and `=` reads it as the type of `x`. Thus `'a '` matches a `char(3)` `'a'` in one query and not in the other.

Each column in `y` must meet one of these conditions:

- The column is qualified.
- The column is unqualified, and `S` is a single table.
- The column is unqualified, `S` is all plain tables, and the catalog says that only one of these tables has that column.

In the two unqualified cases, the rule then qualifies the column with that table.

The original FROM can have an item under such a qualifier. In that case, the rule gives that `S` table a fresh alias. It renames every reference to the table in `S`, also in the subqueries of `S`. Thus the rule refuses if any other FROM item anywhere in `S` has that name. Such an item can be a table, a CTE read, an alias, or an unaliased function call.

Every original FROM item must have a name.

The subquery must be a plain `SELECT` with no `DISTINCT`, `GROUP BY`, `HAVING`, `LIMIT`, `OFFSET`, or set operation. The rule refuses `= ANY`, `NOT IN`, and a query that calls a volatile function.

Postgres must be able to prepare the rewrite. Each placeholder is declared with the type of its literal, as for the original. Thus `generate_series($1, $2)` prepares. This condition refuses a correlated subquery, because only `S` is in scope at the top.

Unsupported in v1: the rule refuses a bare name that names a FROM item on its own side, such as `posts` in `posts IS NULL`. Postgres reads a bare name as a column of any query in scope before it reads the name as a whole row. The flip puts each side in the scope of the other side. A column of that name on the other side would then capture the bare name. A qualified whole row, such as `posts.*`, is permitted.

Each qualifying `IN` gives its own rewrite. The rule does not yet do the same flip inside an `EXISTS` body.

## What it rests on.

The rule rests on no assumption. Its output returns the same rows as its input on any data that the schema permits.

## Example.

This example is the Rails `exists?` on a relation with an `IN` subquery. The rule lets the table of the subquery drive, and it checks the remainder with `EXISTS`. Rails writes `SELECT 1 AS one ... LIMIT 1`, so the `1`s also become placeholders.

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
SELECT $1 AS one
FROM public.users
WHERE
  users.workflow_state = $2
  AND users.id IN (
    SELECT enrollments.user_id
    FROM public.enrollments
    WHERE enrollments.course_id = $3
  )
LIMIT $4
```

After:

```sql
SELECT $1 AS one
FROM public.enrollments
WHERE
  enrollments.course_id = $3
  AND EXISTS (
    SELECT 1
    FROM public.users
    WHERE
      users.workflow_state = $2
      AND users.id = enrollments.user_id
  )
LIMIT $4
```
