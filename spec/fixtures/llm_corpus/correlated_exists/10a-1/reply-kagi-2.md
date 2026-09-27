```json
{
  "inserts": [
    "INSERT INTO public.users (id, email, name, country, status, created_at) VALUES (1, 'u1@example.com', 'User One', 'US', 'active', '2020-01-01 00:00:00+00')",
    "INSERT INTO public.products (id, sku, name, category, price_cents) VALUES (1, 'SKU-1', 'Boundary Pass', $1, 100), (2, 'SKU-2', 'Qty Just Below', $1, 100), (3, 'SKU-3', 'Created Just Before', $1, 100), (4, 'SKU-4', 'Wrong Category', 'not-the-category', 100), (5, 'SKU-5', 'Case Mismatch', upper($1), 100), (6, 'SKU-6', 'No Line Items', $1, 100)",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (1, 1, 'paid', 100, $3, $3), (2, 1, 'paid', 100, $3, $3), (3, 1, 'paid', 100, '2020-01-01 00:00:00+00', '2020-01-01 00:00:00+00'), (4, 1, 'paid', 100, $3, $3)",
    "INSERT INTO public.line_items (id, order_id, product_id, quantity, unit_price_cents) VALUES (1, 1, 1, $4, 100), (2, 2, 2, $4 - 1, 100), (3, 3, 3, $4, 100), (4, 4, 4, $4, 100)"
  ]
}
```
