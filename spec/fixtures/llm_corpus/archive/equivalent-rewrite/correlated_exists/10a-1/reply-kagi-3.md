```json
{
  "inserts": [
    "INSERT INTO public.products (id, sku, name, category, price_cents) VALUES (9001, 'FIX-PROD-01', 'Fixture Widget', $1, 100), (9002, 'FIX-PROD-02', 'Fixture Widget Negative Cat', 'not-' || $1, 100), (9003, 'FIX-PROD-03', 'Fixture Widget Upper Cat', upper($1), 100)",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (8001, 7001, 'paid', 200, $3, $3), (8002, 7001, 'paid', 200, $3 - interval '1 microsecond', $3), (8003, 7001, 'paid', 200, $3 + interval '1 day', $3 + interval '1 day')",
    "INSERT INTO public.line_items (id, order_id, product_id, quantity, unit_price_cents) VALUES (6001, 8001, 9001, $4, 100), (6002, 8002, 9001, $4, 100), (6003, 8003, 9001, $4 - 1, 100), (6004, 8003, 9001, $4 + 1, 100), (6005, 8001, 9002, $4, 100), (6006, 8001, 9003, $4, 100)"
  ]
}
```
