SELECT c.id, c.email,
       (SELECT max(o.created_at) FROM public.orders o WHERE o.customer_id = c.id) AS last_order
FROM public.customers c
WHERE c.tier = 'gold'
  AND (SELECT max(o.created_at) FROM public.orders o WHERE o.customer_id = c.id)
      < '2025-12-10 00:00:00+00';
