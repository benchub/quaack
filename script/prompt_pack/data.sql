-- Rows for the prompt pack's schema, enough for real plans, and the same on
-- every run. run.rb adds the rows the queries' sentinel literals find, then
-- runs ANALYZE.

INSERT INTO public.users (email, name, country, status, created_at)
SELECT 'user' || i || '@example.com', 'User ' || i,
       (ARRAY['US', 'US', 'US', 'GB', 'DE', 'FR', 'CA', 'BR'])[1 + i % 8],
       (ARRAY['active', 'active', 'active', 'active', 'suspended', 'closed'])[1 + i % 6],
       timestamptz '2023-01-01 00:00:00+00' + (i * interval '47 minutes')
FROM generate_series(1, 20000) AS i;

INSERT INTO public.products (sku, name, category, price_cents)
SELECT 'SKU-' || lpad(i::text, 5, '0'), 'Product ' || i,
       (ARRAY['books', 'games', 'garden', 'kitchen', 'toys', 'tools'])[1 + i % 6],
       100 + (i * 37) % 20000
FROM generate_series(1, 2000) AS i;

INSERT INTO public.orders (user_id, status, total_cents, created_at, updated_at)
SELECT 1 + (i * 7919) % 20000,
       (ARRAY['delivered', 'delivered', 'delivered', 'shipped', 'pending', 'cancelled', 'refunded'])[1 + i % 7],
       500 + (i * 131) % 50000,
       timestamptz '2024-01-01 00:00:00+00' + (i * interval '5 minutes'),
       timestamptz '2024-01-01 00:00:00+00' + (i * interval '5 minutes') + interval '2 days'
FROM generate_series(1, 100000) AS i;

INSERT INTO public.line_items (order_id, product_id, quantity, unit_price_cents)
SELECT 1 + i / 3, 1 + (i * 613) % 2000, 1 + i % 4, 100 + (i * 37) % 20000
FROM generate_series(0, 299999) AS i;
