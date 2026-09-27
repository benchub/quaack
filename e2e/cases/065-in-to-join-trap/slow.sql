SELECT c.id, c.email
FROM public.customers c
WHERE c.id IN (SELECT o.customer_id FROM public.orders o
               WHERE o.created_at >= '2025-10-01 00:00:00+00');
