{"inserts": [
"INSERT INTO public.users (email, name, country, status, created_at) VALUES ('Case@Example.com', 'Case', 'DE', 'inactive', '-infinity'::timestamptz), ('case@example.com', NULL, 'de', 'active', 'infinity'::timestamptz)",
"INSERT INTO public.orders (user_id, status, total_cents, created_at, updated_at) VALUES (2, 'shipped', 0, 'infinity'::timestamptz, 'infinity'::timestamptz), (1, 'cancelled', -1, $3, $3), (2, 'pending', 2147483647, '-infinity'::timestamptz, $3)",
"INSERT INTO public.products (sku, name, category, price_cents) VALUES ('sku-x', 'x', upper($1), 0), ('SKU-X', 'X', lower($1), 0), ('sku-y', '', $1 || ' ', -1), ('sku-z', 'Z', ' ' || $1, 2147483647), ('sku-w', 'W', $1, 0), ('sku-v', 'V', $1, 0), ('sku-u', 'U', $1, 0)",
"INSERT INTO public.line_items (order_id, product_id, quantity, unit_price_cents) VALUES (1, 1, $4 + 1, 0), (1, 2, $4 + 1, 0), (1, 3, $4, 0), (1, 4, $4, 0), (1, 5, $4 + 1, 0), (3, 5, $4 - 1, 0), (2, 6, $4, 0), (2, 6, $4 + 1, 0), (3, 6, $4, 0), (3, 7, $4 + 1, 0), (2, 7, $4 - 1, 0)"
]}
