# or_to_union.

An OR whose arms read different tables or subqueries becomes a UNION of one query per arm. The rest of the query reads the UNION in place of its tables.

This rule is one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

A top-level `OR` whose arms read different tables or subqueries becomes a `UNION` of one query per arm. Each of these queries has the `FROM` and `WHERE` of the original query, with only that arm in the place of the `OR`. Each arm selects the columns that the rest of the query uses, and a key of every `FROM` table. The query then reads the `UNION` in place of its tables. Thus its select list, aggregates, `DISTINCT`, `ORDER BY`, and `LIMIT` apply to the whole `UNION`.

The rule does not change a query when:

- The query has `GROUP BY`, `HAVING`, a window function, `DISTINCT ON`, a locking clause, `WITH`, or `INTO`.
- Its `FROM` has an outer join, a `NATURAL` join, a join with `USING`, a join with an alias, or an item that is not a schema-qualified table. A table that the query reads with `ONLY` also counts. A table under an alias that renames its columns also counts.
- Outside the `WHERE`, the query has a subquery in the select list or in the `ORDER BY`.
- Outside the `WHERE`, a column is not written as `name.column` (for example, an unqualified column or a bare `*`), or the `ORDER BY` names an output column. In the arms of the `OR`, outside their subqueries, every column must also be written as `name.column`.
- A select-list entry with no `AS` contains a column, but the entry is not a column, a function call, or an operator. Examples are a cast, a `COALESCE`, or a `CASE` over a column. A cast takes its name from its column, and the `UNION` renames that column. Thus the rule does not change a query with any of these entries.
- The query uses a column of a type that `UNION` cannot compare, such as `json`.
- A `FROM` table has no key that the catalog proves. Such a key is a unique index of one or more columns, with these properties:
  - It has no predicate and no expression.
  - It is not deferrable.
  - It compares each column as the column's own `=` compares it.
  - All its columns are `NOT NULL`, and of types that `UNION` compares.

  A key with a nullable column does not count, even under `NULLS NOT DISTINCT`. A key with a domain or `citext` column also does not count, because the rule does not know that `UNION` compares those types. An index that names a column twice, such as `(a, b, a)`, is the key `(a, b)`.
- An arm has a `LIKE` or `ILIKE`, and one of these is true: the database has a column, domain, or range with a nondeterministic collation, or the `LIKE` names a collation with `COLLATE`. `ILIKE` raises an error on a nondeterministic collation. Before Postgres 18, `LIKE` also raises an error on one. In both cases, the error occurs only when Postgres reads a row.
- An arm has a `LIKE` or `ILIKE` whose constant pattern contains a backslash, and `standard_conforming_strings` is off on the racetrack session. In that case, the server reads the backslashes differently from QUAACK's parser. The rule reads that setting only on the racetrack session. It does not check the setting on production, and nothing records the setting. Unsupported in v1: QUAACK reads every query as `standard_conforming_strings = on` reads it.
- An arm of the `OR`, including its subqueries, contains something that can raise an error on some rows. These things are a cast, a function call, or an operator other than a comparison (such as `/` or `%`) over a column, an index into a column, or a subquery used as a value. Such an item with no column in it, such as `'10'::int`, is permitted. A `LIKE` or `ILIKE` is also permitted when its pattern is a parameter, or a string constant that does not end in the escape character, `\`. A column pattern can end in that character, and Postgres raises an error for this only when it reads a row. Thus a column pattern prevents the split of the `OR`. `NULL` and `ESCAPE` also prevent the split.

That last refusal is important because Postgres runs the arms of an `OR` in order, and stops at the first arm that is true. In `o.vip OR i.total / i.qty > 10`, the first arm prevents the division on the rows of a VIP, where `i.qty` can be 0. After the split, each arm runs independently. Then the division would raise an error where the original query returns rows.

The rule does not see the value of a parameter pattern. If the app passes a pattern that ends in a lone backslash, such as `ab\`, the rewrite raises an error where the original possibly does not. This is because the other arm of the original can skip the `LIKE` for a row, but the branch of the `UNION` cannot. In `o.vip OR i.val LIKE $1`, the original returns the rows of a VIP without the `LIKE`. But the branch with `i.val LIKE $1` runs the `LIKE` on every row, and raises "LIKE pattern must not end with escape character".

QUAACK makes every constant a parameter before the rule runs. Thus most `LIKE` arms come to the rule with a parameter pattern. QUAACK accepts the risk of such a parameter pattern. It does not refuse every `LIKE` arm.

The rule reads only the parse tree. Thus it does not see the casts that the planner adds when the two sides of an operator have different types. `n.amount = r.ratio`, a `numeric` against a `real`, compares as `double precision`. An amount that is too large for `double precision`, such as `1e400`, raises an error. The rule splits that `OR` anyway. Thus such an arm can raise an error in the `UNION` where the original returns rows.

Arms that read the same tables and have no subquery stay together in one query of the `UNION`, as an `OR` in their order. Thus `i.qty = 0 OR i.total > 10 OR o.vip` becomes two queries, not three.

## What it rests on.

The rule needs a unique key of every `FROM` table, of one or more columns, each of which is not null. With this key, `UNION` removes exactly the rows that both arms return. The rule applies only when it can prove this. It states the catalog facts that it relies on as assumptions. assumption-check checks these assumptions again, as it checks all other assumptions.

A key of several columns works like a key of one column. Each arm selects every column of the key. Thus two rows of the join that differ in any of these columns stay separate. The unique index of the key must compare each column as the column's own `=` compares it. Every column must be `NOT NULL`, because `UNION` treats two `NULL`s as the same, and two rows of a unique index can both have `NULL` in a column.

If a table has more than one key, the rule selects a key as follows:

- If the table has a key of one column, the rule selects it. If the table has more than one such key, the rule selects the first one in the table's order.
- If not, the rule selects the key with the fewest columns. If more than one key has that number of columns, the rule selects the index that was made first.

For a key `(a_id, n)`, the rule states: `public.pair (a_id, n)` is unique; `public.pair.a_id` and `public.pair.n` are not null.

Here, the rule states: `public.users (id)` is unique; `public.users.id` is not null.

## Example.

This example has an `OR` of two `IN` subqueries on different tables. The rule makes one query per arm, and reads the `UNION` of these queries. `users.id` is the primary key. Thus `UNION` removes only a user that both arms return.

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
