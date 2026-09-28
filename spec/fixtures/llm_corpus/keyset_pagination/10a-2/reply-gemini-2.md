{
"inserts": [
"INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (1, 1, 'pending', 500, $1, $1), ($2, 1, 'completed', 1000, $1, $1), ($2 - 1, 2, 'pending', 750, $1, $1), ($2 + 1, 2, 'shipped', 250, $1, $1), (1000, 3, 'completed', 100, $1 - interval '1 day', $1), (2000, 3, 'completed', 100, $1 + interval '1 day', $1)"
]
}
