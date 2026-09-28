{
"inserts": [
"INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (1, 1, 'pending', 100, $1 - interval '1 day', $1 + interval '1 day'), (2, 1, 'pending', 200, $1 - interval '2 days', $1 + interval '1 day'), (3, 1, 'pending', 300, $1 - interval '3 days', $1 - interval '4 days');"
]
}
