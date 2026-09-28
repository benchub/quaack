```json
{"inserts":["INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (OVERRIDING SYSTEM VALUE 1, 100, 'paid', 100, $1 - interval '1 hour', $1 + interval '1 hour'), (OVERRIDING SYSTEM VALUE 2, 100, 'paid', 200, $1 - interval '2 hours', $1 - interval '2 hours'), (OVERRIDING SYSTEM VALUE 3, 100, 'paid', 300, $1, $1 + interval '5 minutes'), (OVERRIDING SYSTEM VALUE 4, 100, 'paid', 400, $1 - interval '3 hours', $1 - interval '1 hour')"]}
```
