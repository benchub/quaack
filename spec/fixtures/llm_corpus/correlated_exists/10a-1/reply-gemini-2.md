{
  "inserts": [
    "INSERT INTO public.users (id, email, name, country, status, created_at) VALUES (1, 'user1@example.com', 'Alice', 'US', 'active', '2020-01-01 00:00:00+00');",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (1, 1, 'shipped', 10000, $3, $3);",
    "INSERT INTO public.products (id, sku, name, category, price_cents) VALUES (1, 'SKU-001', 'Widget A', $1, 5000), (2, 'SKU-002', 'Widget B', $1, 5000);",
    "INSERT INTO public.line_items (id, order_id, product_id, quantity, unit_price_cents) VALUES (1, 1, 1, $4, 5000);"
  ]
}
