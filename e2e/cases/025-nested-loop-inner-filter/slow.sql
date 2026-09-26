SELECT c.id, c.email, o.id AS order_id, o.created_at
FROM public.customers c
JOIN public.orders o ON o.customer_id = c.id
WHERE c.tier = 'gold' AND c.region = 'apac' AND o.status = 'pending';
