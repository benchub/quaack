```json
{
  "inserts": [
    "INSERT INTO public.users (id, email, country, status, created_at) OVERRIDING SYSTEM VALUE VALUES (1, 'test@example.com', 'US', 'active', '2026-01-01 00:00:00+00')",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (101, 1, $1, 1000, '2026-01-01 00:00:00+00', '2026-01-01 00:00:00+00')"
  ]
}

```
