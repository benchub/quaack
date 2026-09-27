{
  "inserts": [
    "INSERT INTO public.users (email, name, country, status, created_at) VALUES ('alice@example.com', 'Alice', 'US', 'active', '2022-01-01T00:00:00Z'), ('bob@example.com', 'Bob', 'CA', 'inactive', '2022-01-02T00:00:00Z');",
    "INSERT INTO public.products (sku, name, category, price_cents) VALUES ('sku-100', 'Widget A', $1, 1500), ('sku-200', 'Widget B', 'other_category', 2500);",
    "INSERT INTO public.orders (user_id, status, total_cents, created_at, updated_at) VALUES (1, 'shipped', 1500, $3, '2022-02-01T00:00:00Z'), (2, 'pending', 2500, '2000-01-01T00:00:00Z', '2022-02-02T00:00:00Z');",
    "INSERT INTO public.line_items (order_id, product_id, quantity, unit_price_cents) VALUES (1, 1, $4, 1500), (2, 2, 1, 2500);"
  ]
}
