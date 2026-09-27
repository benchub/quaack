{
  "inserts": [
    "INSERT INTO public.products (id, sku, name, category, price_cents) VALUES (1, 'sku1', 'name1', $1, 100), (2, 'sku2', 'name2', 'other', 200), (3, 'sku3', 'name3', $1, 300);",
    "INSERT INTO public.users (id, email, name, country, status, created_at) VALUES (1, 'user1@example.com', 'user1', 'US', 'active', '2026-01-01 00:00:00+00');",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (1, 1, 'pending', 100, $3, '2026-01-01 00:00:00+00'), (2, 1, 'shipped', 200, '1999-01-01 00:00:00+00', '1999-01-01 00:00:00+00');",
    "INSERT INTO public.line_items (id, order_id, product_id, quantity, unit_price_cents) VALUES (1, 1, 1, $4, 100), (2, 1, 2, $4, 200), (3, 2, 3, $4, 300), (4, 1, 3, 0, 300);"
  ]
}
