SELECT c.region
FROM public.customers c
JOIN public.orders o ON o.customer_id = c.id
WHERE o.created_at >= '2025-12-10 00:00:00+00';
