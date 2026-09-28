{
"inserts": [
"INSERT INTO public.users (id, email, name, country, status, created_at) OVERRIDING SYSTEM VALUE VALUES (1, 'u1@example.com', 'User 1', 'US', 'active', '2020-01-01T00:00:00Z');",
"INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (1, 1, 'pending', 100, $1, $1), (2, 1, 'pending', 200, $1, $1), (3, 1, 'pending', 300, '2020-01-01T00:00:00Z', '2020-01-01T00:00:00Z'), (4, 1, 'pending', 400, '2030-01-01T00:00:00Z', '2030-01-01T00:00:00Z');"
]
}
