# key_in_self_join.

The rule changes an IN subquery that reads the outer table again by a unique, not-null key. The result is the predicates of that table, and an EXISTS on what remains of the subquery.

This rule is one of QUAACK's mechanical rewrite rules (see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).

## What it does.

The rule applies to `t.k IN (SELECT t2.k FROM t t2 ... WHERE P)`, where the subquery reads the outer table again by a key. The rule removes the inner `t2`, and moves its predicates to the outer `t`. It keeps an `EXISTS` on what remains of the subquery, correlated on `t.k`. If nothing remains, only the predicates remain. The rule handles each arm of a `UNION ALL` in the subquery separately, and joins the arms with `OR`.

## What it rests on.

The rule needs `k` to be unique and not null. The rule applies only when it can prove this. It states the catalog facts that it relies on as assumptions. assumption-check checks these assumptions again, as it checks all other assumptions.

Here, the rule states: `public.users (id)` is unique; `public.users.id` is not null.

## Example.

This example has an `IN` subquery that reads `users` again by its primary key. The rule moves the subquery's filter on `users` to the outer `users`. It keeps an `EXISTS` on `enrollments`.

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
SELECT users.*
FROM public.users
WHERE
  users.id IN (
    SELECT u2.id
    FROM
      public.users u2
      JOIN public.enrollments ON enrollments.user_id = u2.id
    WHERE
      u2.workflow_state = $1
      AND enrollments.course_id = $2
  )
```

After:

```sql
SELECT users.*
FROM public.users
WHERE
  users.workflow_state = $1
  AND EXISTS (
    SELECT 1
    FROM public.enrollments enrollments_1
    WHERE
      enrollments_1.course_id = $2
      AND enrollments_1.user_id = users.id
  )
```
