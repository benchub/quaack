SELECT c.id, c.email, m.last_order
FROM public.customers c
CROSS JOIN LATERAL (
    SELECT max(o.created_at) AS last_order FROM public.orders o WHERE o.customer_id = c.id
) m
WHERE c.tier = 'gold'
  AND m.last_order < '2025-12-10 00:00:00+00';
