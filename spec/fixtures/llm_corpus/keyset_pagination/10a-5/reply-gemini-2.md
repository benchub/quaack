```json
{
  "inserts": [
    "INSERT INTO public.users OVERRIDING SYSTEM VALUE (id, email, country, status, created_at) VALUES (1, 'user@example.com', 'US', 'active', '2020-01-01');",
    "INSERT INTO public.orders OVERRIDING SYSTEM VALUE (id, user_id, status, total_cents, created_at, updated_at) VALUES (1, 1, 'pending', 100, $1 - interval '1 day', $1);"
  ]
}

```
