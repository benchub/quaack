{
"inserts": [
"INSERT INTO public.users (id, email, country, status, created_at) VALUES (1, 'u1@example.com', $1, 'active', $2), (2, 'u2@example.com', $1, 'active', $2);",
"INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (1, 1, 'pending', 100, $2, $2), (2, 1, 'pending', 200, $2, $2), (3, 2, 'pending', 300, $2, $2), (4, 2, 'pending', 400, $2, $2), (5, 1, 'pending', 500, $2, $2);"
]
}
