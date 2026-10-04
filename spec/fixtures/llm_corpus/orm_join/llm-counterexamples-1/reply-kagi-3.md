{
  "inserts": [
    "INSERT INTO public.users (id, email, name, country, status, created_at) VALUES (DEFAULT, 'a@ex.com', 'Ann', $1, 'active', '2020-01-01 00:00:00+00'), (DEFAULT, 'b@ex.com', 'Bob', $1, 'active', '2020-01-02 00:00:00+00'), (DEFAULT, 'c@ex.com', 'Cal', 'ZZ', 'active', '2020-01-03 00:00:00+00')",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (DEFAULT, 1, 'new', 100, $2, $2), (DEFAULT, 1, 'new', 200, ($2 - interval '1 second'), ($2 - interval '1 second')), (DEFAULT, 1, 'new', 300, ($3 - interval '1 microsecond')), (DEFAULT, 1, 'new', 400, $3, $3), (DEFAULT, 1, 'new', 500, ($2 - interval '1 hour')), ($2 - interval '1 hour')), (DEFAULT, 2, 'new', 600, $2, $2)",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (DEFAULT, 1, 'paid', 10, '2025-06-01 12:00:00+00', '2025-06-01 12:00:00+00'), (DEFAULT, 1, 'paid', 20, '2025-06-01 12:00:00+00', '2025-06-01 12:00:00+00'), (DEFAULT, 2, 'paid', 30, '2025-06-01 12:00:00+00', '2025-06-01 12:00:00+00'), (DEFAULT, 2, 'paid', 40, '2025-06-01 12:00:00+00', '2025-06-01 12:00:00+00'), (DEFAULT, 2, 'paid', 50, '2025-06-01 11:59:59+00', '2025-06-01 11:59:59+00'), (DEFAULT, 3, 'new', 999, '2025-06-01 12:00:30+00', '2025-06-01 12:00:30+00')"
  ]
}
