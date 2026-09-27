{
  "inserts": [
    "INSERT INTO public.products (id, sku, name, category, price_cents) VALUES (1, 'SKU1', 'Name1', $1, 1000);",
    "INSERT INTO public.users (id, email, country, status, created_at) VALUES (1, 'test@example.com', 'US', 'active', '2020-01-01 00:00:00Z');",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (1, 1, 'completed', 1000, $3, '2020-01-01 00:00:00Z');",
    "INSERT INTO public.line_items (id, order_id, product_id, quantity, unit_price_cents) VALUES (1, 1, 1, $4, 1000);"
  ]
}
