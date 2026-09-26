SELECT o.id, o.created_at, o.total_cents
FROM public.orders o
JOIN public.customers c ON c.id = o.customer_id
WHERE o.created_at >= '2025-12-01 00:00:00+00';
