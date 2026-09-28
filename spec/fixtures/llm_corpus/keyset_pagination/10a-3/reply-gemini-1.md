{
"inserts": [
"INSERT INTO public.users (id, email, name, country, status, created_at) OVERRIDING SYSTEM VALUE VALUES (1, 'a@example.com', 'A', 'US', 'active', '2020-01-01 00:00:00+00');",
"INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES ($2 - 1, 1, 'pending', 1000, $1, '2020-01-01 00:00:00+00'), ($2, 1, 'pending', 2000, $1, '2020-01-01 00:00:00+00'), ($2 + 1, 1, 'pending', 3000, $1, '2020-01-01 00:00:00+00');"
]
}
