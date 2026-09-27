```json
{
  "inserts": [
    "INSERT INTO public.users (id, email, name, country, status, created_at) VALUES (2, 'u2@example.com', NULL, 'CA', 'active', '2021-06-15 12:00:00+00')",
    "INSERT INTO public.products (id, sku, name, category, price_cents) VALUES (201, 'SKU-E', 'Just Below Date', $1, 100), (202, 'SKU-F', 'Mixed Qty Same Order', $1, 100), (203, 'SKU-G', 'Two Orders Split', $1, 100), (204, 'SKU-H', 'Category Mismatch Qualifies', $1 || 'x', 100)",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) VALUES (301, 2, 'paid', 500, $3 - interval '1 microsecond', $3 - interval '1 microsecond'), (302, 2, 'pending', 500, $3 + interval '1 second', $3 + interval '1 second'), (303, 2, 'cancelled', 500, '1999-12-31 23:59:59+00', '1999-12-31 23:59:59+00')",
    "INSERT INTO public.line_items (id, order_id, product_id, quantity, unit_price_cents) VALUES (401, 301, 201, $4, 100), (402, 302, 202, $4 - 1, 100), (403, 302, 202, $4, 100), (404, 303, 203, $4, 100), (405, 302, 203, $4 + 1, 100), (406, 302, 204, $4, 100)"
  ]
}
```

This round targets different edges than the accepted set:

- **Sub-microsecond boundary on `$3`**: order 301 sits at `$3 - interval '1 microsecond'`, just below the `>= $3` cutoff — tighter than the exact-boundary row already accepted.
- **Quantity just below `$4`**: item 402 uses `$4 - 1`, failing the quantity predicate while item 403 (same product, same order) qualifies — exercising multiple line items per product and per order in one EXISTS.
- **Split across orders**: product 203 fails via an old order (303) but qualifies via a newer one (302), so the EXISTS must scan both.
- **Category mismatch with a fully qualifying line item**: product 204 has category `$1 || 'x'` (so it differs from `$1` by appended text, not just case) and an otherwise-perfect line item, isolating the category filter.
- **NULL and other unused columns**: user row has NULL `name`; order statuses vary (`pending`, `cancelled`) to confirm status is not part of either query.
