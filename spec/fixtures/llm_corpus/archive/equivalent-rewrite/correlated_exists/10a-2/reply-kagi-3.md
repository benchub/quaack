{
  "inserts": [
    "INSERT INTO public.users (email, name, country, status, created_at) VALUES ('split-user@example.com', NULL, 'US', 'active', '2019-06-15T12:00:00Z')",
    "INSERT INTO public.products (sku, name, category, price_cents) VALUES ('SPLIT-A', 'Time Pass Qty Fail', $1, 100), ('SPLIT-B', 'Qty Pass Time Fail', $1, 100), ('SPLIT-C', 'All Conditions Pass', $1, 100), ('SPLIT-D', 'Only One Good Item', $1, 100)",
    "INSERT INTO public.orders (user_id, status, total_cents, created_at, updated_at) VALUES (1, 'paid', 100, $3 + interval '1 hour', $3 + interval '1 hour'), (2, 'paid', 100, $3 - interval '1 day', $3 - interval '1 day'), (3, 'paid', 100, $3 + interval '1 microsecond', $3 + interval '1 microsecond'), (4, 'paid', 400, $3 + interval '1 year', $3 + interval '1 year'), (4, 'refunded', 400, $3 - interval '1 year', $3 - interval '1 year')",
    "INSERT INTO public.line_items (order_id, product_id, quantity, unit_price_cents) VALUES (1, 1, $4 - 1, 100), (2, 2, $4, 100), (3, 3, $4, 100), (4, 4, $4, 100), (5, 4, $4 - 2, 100)"
  ]
}
