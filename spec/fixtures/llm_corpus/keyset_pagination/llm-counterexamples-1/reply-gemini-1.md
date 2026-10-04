{
"inserts": [
"INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES ($2 - 1, 1, 'pending', 1000, $1, '2026-01-01T00:00:00Z'), ($2, 1, 'completed', 2000, $1, '2026-01-01T00:00:00Z'), ($2 + 1, 1, 'shipped', 3000, $1, '2026-01-01T00:00:00Z'), ($2 + 2, 1, 'pending', 4000, $1 - interval '1 day', '2026-01-01T00:00:00Z');"
]
}
