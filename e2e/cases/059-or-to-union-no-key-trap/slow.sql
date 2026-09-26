SELECT customer_id, status
FROM public.orders
WHERE customer_id = 4242 OR status = 'cancelled';
