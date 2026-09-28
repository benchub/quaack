```json
{"inserts":["INSERT INTO public.products (sku, name, category, price_cents) VALUES ('SKU-A', 'SKU-A', $1, 100), ('SKU-B', 'Some Name', $1, 200)","INSERT INTO public.users (email, country, status, created_at) VALUES ('t@example.com', 'US', 'active', now())","INSERT INTO public.orders (user_id, status, total_cents, created_at, updated_at) VALUES ((SELECT 1), 'shipped', 300, $3, $3)","INSERT INTO public.line_items (order_id, product_id, quantity, unit_price_cents) VALUES (1, 1, $4, 100), (1, 2, $4, 200)"]}
```
