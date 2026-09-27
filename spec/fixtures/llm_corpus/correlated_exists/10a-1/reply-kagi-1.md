```json
{
  "inserts": [
    "INSERT INTO public.products (sku, name, category, price_cents) VALUES ('cx-a', 'atom-cat-hit', $1, 100), ('cx-b', 'atom-cat-miss', upper($1) || '_other', 200), ('cx-c', 'atom-cat-hit2', $1, 300)",
    "INSERT INTO public.orders (user_id, status, total_cents, created_at, updated_at) VALUES (1, 'shipped', 100, $3, $3), (1, 'shipped', 100, '2000-01-01T00:00:00+00'::timestamptz, $3), (1, 'pending', 100, TIMESTAMPTZ '1999-12-31 23:59:59+00', $3)",
    "INSERT INTO public.line_items (order_id, product_id, quantity, unit_price_cents) VALUES (1, 1, $4, 100), (1, 2, 0, 100), (2, 1, 2147483647, 100), (2, 2, -2147483648, 100), (3, 3, $4, 100)"
  ]
}
```

Notes on what these rows aim at:

- **`p.category = $1`**: exercised both passing (`cx-a`, `cx-c`) and failing (`cx-b`, using a case-distinct value via `upper($1)`).
- **`o.created_at >= $3`**: boundary pass (`$3` exactly), clear fail (old constant timestamps in 1999/2000).
- **`li.quantity >= $4`**: boundary pass (`$4` exactly), large pass, and fails at both extremes (`0`, integer minimum).
- **EXISTS false via no matching line items**: `cx-c` has a matching-category path only through a pre-`$3` order, and negative-quantity rows test the inner conjunction failing independently.

The two queries are semantically equivalent (a materialized CTE of the identical body followed by `ORDER BY id` on a primary key, which is unique and non-NULL), so no row set can make them diverge; these inserts instead maximize coverage of every predicate atom in both directions. Dangling `order_id`/`user_id`/`product_id` foreign keys are left for the enclave to fill with parent rows. Identity `id` columns are omitted since they are `GENERATED ALWAYS` and explicit ids would require refused `OVERRIDING`.
