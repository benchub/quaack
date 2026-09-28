```json
{
  "inserts": [
    "INSERT INTO public.users (id, email, name, country, status, created_at, updated_at) VALUES (1, 'a1@example.com', 'A', 'US', 'active', '2026-01-01 00:00:00+00', '2026-01-01 00:00:00+00')",
    "INSERT INTO public.users (id, email, name, country, status, created_at, updated_at) VALUES (2, 'a2@example.com', 'B', 'US', 'active', '2026-01-01 00:00:00+00', '2026-01-01 00:00:00+00')",
    "INSERT INTO public.users (id, email, name, country, status, created_at, updated_at) VALUES (3, 'a3@example.com', 'C', 'US', 'active', '2026-01-01 00:00:00+00', '2026-01-01 00:00:00+00')",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (1, 1, $1, -500, '2026-01-02 00:00:00+00', '2026-01-02 00:00:00+00'), (2, 1, $1, 100, '2026-01-03 00:00:00+00', '2026-01-03 00:00:00+00'), (3, 1, $1, 200, '2026-01-04 00:00:00+00', '2026-01-04 00:00:00+00'), (4, 1, 'other', 99999, '2026-01-05 00:00:00+00', '2026-01-05 00:00:00+00')",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (5, 2, $1, 50, '2026-01-02 00:00:00+00', '2026-01-02 00:00:00+00'), (6, 2, $1, 60, '2026-01-03 00:00:00+00', '2026-01-03 00:00:00+00'), (7, 2, $1, 0, '2026-01-04 00:00:00+00', '2026-01-04 00:00:00+00')",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (8, 3, $1, -100, '2026-01-02 00:00:00+00', '2026-01-02 00:00:00+00'), (9, 3, $1, -200, '2026-01-03 00:00:00+00', '2026-01-03 00:00:00+00'), (10, 3, $1, -300, '2026-01-04 00:00:00+00', '2026-01-04 00:00:00+00')"
  ]
}
```

Key differences exercised: user 1 and user 3 have `status = $1` orders with negative `total_cents` — the original includes them (spent = -200 and -600), but the candidate's added `total_cents >= 0` filter drops them entirely. User 2 (all non-negative) exercises the `status = $1` predicate both passing and failing (order 4 has a different status), plus a zero boundary value.
