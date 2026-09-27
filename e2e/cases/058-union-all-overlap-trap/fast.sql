SELECT id, created_at FROM public.orders WHERE customer_id = 5001
UNION ALL
SELECT id, created_at FROM public.orders WHERE created_at >= '2025-12-10 00:00:00+00';
