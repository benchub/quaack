```json
{
  "inserts": [
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES ($2, 1, 'pending', 100, $1 - interval '1 day', $1);"
  ]
}

```
