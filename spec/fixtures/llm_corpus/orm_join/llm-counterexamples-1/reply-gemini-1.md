{
"inserts": [
"INSERT INTO public.users (email, name, country, status, created_at) VALUES ('user1@example.com', 'User One', $1, 'active', $2), ('user2@example.com', 'User Two', $1, 'active', $2), ('user3@example.com', 'User Three', $1, 'active', $2);",
"INSERT INTO public.orders (user_id, status, total_cents, created_at, updated_at) VALUES (1, 'completed', 1000, $2, $2), (2, 'completed', 2000, $2, $2), (3, 'completed', 3000, $2, $2);"
]
}
