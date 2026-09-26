SELECT customer_id, status FROM public.orders WHERE customer_id = 4242
UNION
SELECT customer_id, status FROM public.orders WHERE status = 'cancelled';
