SELECT customer_id FROM public.orders
WHERE customer_id <= 200 AND created_at >= '2025-06-01 00:00:00+00'
EXCEPT ALL
SELECT customer_id FROM public.orders
WHERE customer_id <= 200 AND status = 'pending';
