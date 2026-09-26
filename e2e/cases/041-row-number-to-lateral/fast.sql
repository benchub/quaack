SELECT c.id AS customer_id, r.id, r.created_at
FROM public.customers c
CROSS JOIN LATERAL (
    SELECT o.id, o.created_at
    FROM public.orders o
    WHERE o.customer_id = c.id
    ORDER BY o.created_at DESC, o.id DESC
    LIMIT 3
) r
WHERE c.tier = 'gold';
