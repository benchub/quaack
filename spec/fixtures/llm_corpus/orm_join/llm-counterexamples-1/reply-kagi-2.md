{
  "inserts": [
    "INSERT INTO public.users (id, email, name, country, status, created_at) VALUES (1, 'u1@example.com', 'Match', $1, 'active', '2020-01-01T00:00:00Z'::timestamptz), (2, 'u2@example.com', 'Case', upper($1), 'active', '2020-01-01T00:00:00Z'::timestamptz), (3, 'u3@example.com', 'Other', 'ZZ', 'active', '2020-01-01T00:00:00Z'::timestamptz)",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (1, 1, 'paid', 100, $2, '2020-01-01T00:00:00Z'::timestamptz), (2, 1, 'paid', 200, $2 - interval '1 microsecond', '2020-01-01T00:00:00Z'::timestamptz), (3, 1, 'paid', 300, $3, '2020-01-01T00:00:00Z'::timestamptz), (4, 1, 'paid', 400, $3 - interval '1 microsecond', '2020-01-01T00:00:00Z'::timestamptz), (5, 1, 'paid', 500, $2, '2020-01-01T00:00:00Z'::timestamptz), (6, 1, 'paid', 600, $2, '2020-01-01T00:00:00Z'::timestamptz), (7, 1, 'paid', 700, $2, '2020-01-01T00:00:00Z'::timestamptz), (8, 2, 'paid', 800, $2, '2020-01-01T00:00:00Z'::timestamptz), (9, 3, 'paid', 900, $2, '2020-01-01T00:00:00Z'::timestamptz)"
  ]
}
