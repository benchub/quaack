```json
{"inserts": ["INSERT INTO public.users (id, email, name, country, status, created_at) VALUES (DEFAULT, 'nobody@example.com', NULL, $1, 'active', $2), (DEFAULT, 'somebody@example.com', 'Some Body', $1, 'active', $2)", "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (DEFAULT, 1, 'paid', 1000, $2, $2), (DEFAULT, 2, 'paid', 2000, $2 - interval '1 day', $2 - interval '1 day')"]}
```

The key counterexample: the user with `name = NULL` is filtered out by the candidate's added `u.name IS NOT NULL` predicate, but the original returns their order (created at the lower boundary `$2`, so it passes `>= $2` and sorts newest, so no `LIMIT` hides it). The named user's earlier order keeps both queries non-empty.
