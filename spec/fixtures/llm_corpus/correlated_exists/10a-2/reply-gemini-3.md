{
  "inserts": [
    "INSERT INTO public.users (id, email, country, status, created_at) VALUES (1, 'user1@example.com', 'US', 'active', '2023-01-01 00:00:00Z'), (2, 'user2@example.com', 'UK', 'inactive', '2023-02-01 00:00:00Z');",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (1, 1, 'pending', 1000, $3, '2023-01-01 00:00:00Z'), (2, 2, 'completed', 2000, '2020-01-01 00:00:00Z', '2020-01-02 00:00:00Z');",
    "INSERT INTO public.products (id, sku, name, category, price_cents) VALUES (1, 'SKU-1', 'Product 1', $1, 1000), (2, 'SKU-2', 'Product 2', $1, 2000), (3, 'SKU-3', 'Product 3', 'diff_cat', 3000);",
    "INSERT INTO public.line_items (id, order_id, product_id, quantity, unit_price_cents) VALUES (1, 1, 1, $4, 1000), (2, 1, 2, 0, 2000), (3, 2, 1, $4, 1000), (4, 1, 3, $4, 3000);"
  ]
}
