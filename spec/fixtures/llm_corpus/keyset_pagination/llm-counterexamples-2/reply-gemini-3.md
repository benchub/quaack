{
"inserts": [
"INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES ($2, 1, 'pending', 1000, $1, $1), ($2 - 1, 1, 'completed', 2000, $1, $1), ($2 + 1, 1, 'pending', 1500, $1, $1), ($2, 1, 'cancelled', 500, $1 - interval '1 day', $1), ($2 - 1, 1, 'completed', 3000, $1 - interval '1 day', $1);"
]
}
