SELECT DISTINCT c.id, c.email
FROM public.customers c
JOIN public.orders o ON o.customer_id = c.id
WHERE c.tier = 'gold' AND o.total_cents > 15000;
