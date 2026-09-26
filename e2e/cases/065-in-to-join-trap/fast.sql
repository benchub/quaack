SELECT c.id, c.email
FROM public.customers c
JOIN public.orders o ON o.customer_id = c.id
WHERE o.created_at >= '2025-10-01 00:00:00+00';
