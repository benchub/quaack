SELECT customer_id FROM public.orders
WHERE created_at >= '2025-11-01 00:00:00+00' AND created_at < '2025-11-11 00:00:00+00'
INTERSECT
SELECT customer_id FROM public.orders
WHERE created_at >= '2025-12-01 00:00:00+00' AND created_at < '2025-12-11 00:00:00+00';
