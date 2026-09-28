```json
{
  "inserts": [
    "INSERT INTO public.users (id, email, name, country, status, created_at) OVERRIDING SYSTEM VALUE VALUES (1, 'user1@example.com', 'User One', 'US', 'active', '2023-01-01T00:00:00Z');",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (1, 1, 'pending', 100, $1, '2023-01-01T00:00:00Z'), (2, 1, 'pending', 100, $1, '2023-01-01T00:00:00Z'), (3, 1, 'pending', 100, '2000-01-01T00:00:00Z', '2023-01-01T00:00:00Z'), (4, 1, 'pending', 100, '2040-01-01T00:00:00Z', '2023-01-01T00:00:00Z'), (5, 1, 'pending', 100, $1, '2023-01-01T00:00:00Z');"
  ]
}

```
