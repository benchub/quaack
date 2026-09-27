SELECT customer_id FROM public.orders
WHERE customer_id <= 100 AND created_at < '2025-07-01 00:00:00+00'
INTERSECT
SELECT customer_id FROM public.orders
WHERE customer_id <= 100 AND created_at >= '2025-07-01 00:00:00+00';
