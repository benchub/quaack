{
"inserts": [
"INSERT INTO public.users OVERRIDING SYSTEM VALUE (id, email, name, country, status, created_at) VALUES (1, 'user@example.com', 'User', 'US', 'active', '-infinity');",
"INSERT INTO public.orders OVERRIDING SYSTEM VALUE (id, user_id, status, total_cents, created_at, updated_at) VALUES (-999999, 1, 'pending', 100, '-infinity', 'infinity');"
]
}
