# existence_in_flip.

An existence check under LIMIT 1 is turned inside out: an uncorrelated IN subquery's table drives, and the rest of the query becomes an EXISTS correlated on the IN's two sides.

It's one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

An existence check, a query whose select list is all constants, each perhaps cast, as in `1::integer`, with `LIMIT 1` and no `DISTINCT`, `GROUP BY`, `HAVING`, window, or `OFFSET`, is turned inside out on a top-level `WHERE` conjunct `x IN (SELECT y FROM S WHERE P)`: `SELECT <the same constants> FROM S WHERE P AND EXISTS (SELECT 1 FROM <the original FROM> WHERE <the other conjuncts> AND x = y) LIMIT 1`. So `S` drives, which a `LIMIT 1` fast-start plan from the other side can lose to. The original FROM, outer joins included, moves whole into the `EXISTS`, and the original's CTEs stay at the top. Both return a row exactly when some combination of rows passes every predicate with `x = y`; the `IN` and the `=` use the same operator, so a `NULL` matches nothing in either. It needs `LIMIT 1`, since with more the two can return different numbers of rows. An `ORDER BY` becomes `ORDER BY 1`: every row is the same constants, so the order picks nothing, but result comparison needs a candidate to keep an `ORDER BY` the original has. Each key must be an output position, or a column written `name.column` of a plain table in the original FROM whose type is an enum or a built-in scalar, with no `USING`, since sorting can fail at run time, as `1 / 0` does, or a `json[]` or a whole row with a `json` column does when two rows compare, and the rewrite wouldn't sort them. `y` may be an expression with no subquery, since a bare name in one would see the original FROM first, and not a bare constant, which `IN` reads as `text` and `=` as `x`'s type, so `'a '` matches a `char(3)` `'a'` in one and not the other. Each column in `y` must be qualified, or unqualified with `S` a single table, or with `S` all plain tables of which the catalog says just one has that column; either way it's then qualified with that table. When the original FROM has an item under such a qualifier, that `S` table gets a fresh alias, and every reference to it in `S` is renamed, including in `S`'s subqueries, so nothing else anywhere in `S` may have that name as a FROM item: a table, a CTE read, an alias, or an unaliased function call. Every original FROM item must have a name. The subquery must be a plain `SELECT` with no `DISTINCT`, `GROUP BY`, `HAVING`, `LIMIT`, `OFFSET`, or set operation, and it refuses `= ANY`, `NOT IN`, and a query that calls a volatile function. Postgres must be able to prepare the rewrite, each placeholder declared its literal's type as the original is, so `generate_series($1, $2)` prepares; that refuses a correlated subquery, since only `S` is in scope at the top. Unsupported in v1: a bare name that names a FROM item on its own side, such as `posts` in `posts IS NULL`, is refused. Postgres reads a bare name as a column of any query in scope before it reads it as a whole row, and the flip puts each side in the scope of the other, whose column of that name would capture it. A qualified whole row, such as `posts.*`, is fine. Each qualifying `IN` gives its own rewrite. The same flip inside an `EXISTS` body is left for later.

## What it rests on.

No assumption. Its output returns the same rows as its input on any data the schema allows.

## Example.

Rails' `exists?` on a relation with an `IN` subquery. The rule lets the subquery's table drive, and checks the rest with `EXISTS`. Rails writes `SELECT 1 AS one ... LIMIT 1`, so the `1`s become placeholders too.

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
