{"inserts":["INSERT INTO public.users (id, email, name, country, status, created_at) VALUES (OVERRIDING SYSTEM VALUE ...), ..."]} 

Wait — `OVERRIDING SYSTEM VALUE` goes before `VALUES` inside the INSERT statement, not in the column list. Corrected:

```json
{
  "inserts": [
    "INSERT INTO public.users (id, email, name, country, status, created_at) OVERRIDING SYSTEM VALUE VALUES (9001, 'probe-u1@example.com', 'User One', 'US', 'active', '2025-01-01T00:00:00Z'), (9002, 'probe-u2@example.com', 'User Two', 'US', 'active', '2025-01-01T00:00:00Z')",
    "INSERT INTO public.products (id, sku, name, category, price_cents) OVERRIDING SYSTEM VALUE VALUES (7001, 'PROBE-A1', 'Widget A', $1, 1000), (7002, 'PROBE-A2', 'Widget B', $1, 1000), (7003, 'PROBE-B1', 'Widget C', $1, 1000), (7004, 'PROBE-C1', 'Widget D', upper($1) || '-other', 1000)",
    "INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (8001, 9001, 'paid', 1000, $3, $3), (8002, 9001, 'paid', 1000, $3::timestamptz - interval '1 microsecond', $3), (8003, 9002, 'paid', 1000, '2025-06-01T12:00:00Z', '2025-06-01T12:00:00Z')",
    "INSERT INTO public.line_items (id, order_id, product_id, quantity, unit_price_cents) OVERRIDING SYSTEM VALUE VALUES (6001, 8001, 7001, $4, 100), (6002, 8001, 7002, $4::integer + 1, 100), (6003, 8001, 7003, $4::integer - 1, 100), (6004, 8002, 7002, $4::integer + 10, 100), (6005, 8003, 7003, $4::integer + 10, 100), (6006, 8003, 7004, $4::integer + 10, 100)"
  ]
}
```

**Explanation of what these rows probe** (the candidate is semantically identical — a `MATERIALIZED` CTE wrapping the exact original query, then `ORDER BY id` on `id` which matches the original `ORDER BY p.id` since `r` preserves column names — so a counterexample is unlikely, but these rows exercise every predicate in both passing and failing directions):

- **Product 7001**: category matches `$1`, has a line item at exactly the boundary `created_at >= $3` (equality) with `quantity >= $4` (equality) → should be returned by both queries.
- **Product 7002**: matches category; boundary tests `created_at` one microsecond *before* `$3` (fails the date predicate) but also at/after `$3` in a later order (order 8003) with quantity above `$4` → should be returned by both; also probes quantity `$4 + 1` and `$4 - 1` edges.
- **Product 7003**: category matches, but its only qualifying-order line item has `quantity = $4 - 1` (fails quantity) and the quantity-satisfying line item is on an order before the cutoff → should be excluded by both.
- **Product 7004**: category does not match `$1` (uses `upper($1) || '-other'` as a guaranteed-different constant, avoiding a literal guess), with an otherwise fully qualifying line item → should be excluded by both.
- **Duplicate ids / tie behavior**: both queries order only by `p.id` / `id` (unique primary key), so no tie ambiguity exists.

If the two queries do diverge on your data, these boundary rows (equality vs. off-by-one on `created_at` and `quantity`, and the category non-match) are the likeliest places to catch it.
