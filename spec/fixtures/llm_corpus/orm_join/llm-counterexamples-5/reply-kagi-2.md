{"inserts":["INSERT INTO public.users (id, email, name, country, status, created_at) VALUES (OVERRIDING SYSTEM VALUE ... , ...)"]} 

Wait — that syntax is wrong; `OVERRIDING SYSTEM VALUE` goes before VALUES on the INSERT statement. Correcting:

```json
{"inserts":["INSERT INTO public.users (id, email, name, country, status, created_at) OVERRIDING SYSTEM VALUE VALUES (1, 'a@example.com', NULL, $1, 'active', '2020-01-01T00:00:00Z'::timestamptz), (2, 'b@example.com', 'Bob', $1, 'active', '2020-01-01T00:00:00Z'), (3, 'c@example.com', NULL, 'ZZ', 'active', '2020-01-01T00:00:00Z')","INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (1, 1, 'done', 100, $2, $2), (2, 1, 'done', 200, $3, $3), (3, 1, 'done', 300, ($2 + interval '1 hour')::timestamptz, $2), (4, 2, 'done', 400, $2, $2), (5, 2, 'done', 500, $3, $3), (6, 2, 'done', 600, ($2 + interval '2 hours')::timestamptz, $2), (7, 3, 'done', 700, $2, $2)]"]}
```

**Why this should break the candidate:** the candidate's CTE adds `u.name IS NOT NULL`. Users 1 and 3 have `name = NULL`, so their orders (in-range, right country for user 1) are dropped by the candidate but kept by the original. User 1 has an order exactly at the `$2` boundary (inclusive) and one exactly at `$3` (exclusive), exercising both boundary atoms; user 3 has a NULL-name user with a non-matching country so the filter also fails both ways. User 2's rows exercise the passing side of every predicate.
