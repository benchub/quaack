```json
{"inserts":["INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES ($2, 1, 'paid', 100, $1, $1), ($2 - 1, 1, 'paid', 200, $1, $1), ($2 + 1, 1, 'paid', 300, $1, $1), ($2 + 100, 1, 'paid', 400, $1 - interval '1 second', $1), ($2 - 100, 1, 'paid', 500, $1 + interval '1 second', $1 + interval '1 second'), ($2, 1, 'paid', 600, $1 - interval '1 microsecond', $1), ($2, 1, 'paid', 700, $1 + interval '1 microsecond', $1 + interval '1 microsecond')"]}
```
